# = Event loop driven by Java Non-blocking I/O
# Copyright (C) 2010  Infonium Inc.
#
# This file is part of ScripTTY.
#
# ScripTTY is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ScripTTY is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with ScripTTY.  If not, see <http://www.gnu.org/licenses/>.

raise LoadError.new("This file only works in JRuby") unless defined?(Java)

require 'java'
require 'thread'

module ScripTTY
  module Net
    class EventLoop
      include_class 'java.net.InetSocketAddress'
      include_class 'java.nio.ByteBuffer'
      include_class 'java.nio.channels.SelectionKey'
      include_class 'java.nio.channels.Selector'
      include_class 'java.nio.channels.ServerSocketChannel'
      include_class 'java.nio.channels.SocketChannel'

      def initialize
        @selector = Selector.open
        @read_buffer = ByteBuffer.allocate(4096)
        @exit_mutex = Mutex.new   # protects
        @exit_requested = false
        @timer_queue = []    # sorted list of timers, in ascending order of expire_at time
      end

      # Instruct the main loop to exit.  Returns immediately.
      #
      # - This method may safely be called from any thread.
      # - This method may safely be invoked multiple times.
      def exit
        @exit_mutex.synchronize { @exit_requested = true }
        @selector.wakeup
        nil
      end

      # Listen for TCP connections on the specified address (given as [host, port])
      #
      # If port 0 is specified, the operating system will choose a port.
      #
      # If a block is given, it will be passed the ListeningSocketWrapper
      # object, and the result of the block will be returned.  Otherwise, the
      # ListeningSocketWrapper object is returned.
      #
      # Options:
      # [:multiple]
      #   If true, then the parameter is a list of addresses, the block
      #   will be invoked for each one, and the return value will be an array
      #   of ListeningSocketWrapper objects.
      def listen(address, options={}, &block)
        if options[:multiple]
          # address is actually a list of addresses
          options = options.dup
          options.delete(:multiple)
          return address.map{ |addr| listen(addr, options, &block) }
        end
        bind_address = EventLoop.parse_address(address)
        schan = ServerSocketChannel.open
        schan.configureBlocking(false)
        schan.socket.bind(bind_address)
        lw = ListeningSocketWrapper.new(self, schan)
        schan.register(@selector, 0)
        selection_key = schan.keyFor(@selector)   # SelectionKey object
        selection_key.attach({:listening_socket_wrapper => lw})
        if block
          block.call(lw)
        else
          lw
        end
      end

      # Convenience method: Listen for TCP connections on a particular address
      # (given as [host, port]), and invoke the given block when a connection
      # is received.
      #
      # If port 0 is specified, the operating system will choose a port.
      #
      # Returns the ListeningSocketWrapper.
      #
      # Options:
      # [:multiple]
      #   If true, then the parameter is a list of addresses, and
      #   multiple ListeningSocketWrapper objects will be returned as an array.
      def on_accept(address, options={}, &callback)
        raise ArgumentError.new("no block given") unless callback
        listen(address, options) { |listener| listener.on_accept(&callback) }
      end

      # Initiate a TCP connection to the specified address (given as [host, port])
      #
      # If a block is given, it will be passed the OutgointConnectionWrapper
      # object, and the result of the block will be returned.  Otherwise, the
      # OutgoingConnectionWrapper object is returned.
      def connect(address)
        connect_address = EventLoop.parse_address(address)
        chan = SocketChannel.open
        chan.configureBlocking(false)
        chan.socket.setOOBInline(true)    # Receive TCP URGent data (but not the fact that it's urgent) in-band
        chan.connect(connect_address)
        cw = OutgoingConnectionWrapper.new(self, chan, address)
        chan.register(@selector, 0)
        selection_key = chan.keyFor(@selector)   # SelectionKey object
        selection_key.attach({:connection_wrapper => cw})
        if block_given?
          yield cw
        else
          cw
        end
      end

      # Convenience method: Initiate a TCP connection to the specified
      # address (given as [host, port]) and invoke the given block when a
      # connection is made.
      #
      # Returns the OutgoingConnectionWrapper that will be connected to.
      def on_connect(address, &callback)
        raise ArgumentError.new("no block given") unless callback
        connect(address) { |conn| conn.on_connect(&callback) }
      end

      # Invoke the specified callback after the specified number of seconds
      # have elapsed.
      #
      # Return the ScripTTY::Net::EventLoop::Timer object for the timer.
      def timer(delay, &callback)
        raise ArgumentError.new("no block given") unless callback
        new_timer = Timer.new(self, Time.now + delay, callback)
        i = 0
        while i < @timer_queue.length   # Insert new timer in the correct sort order
          break if @timer_queue[i].expire_at > new_timer.expire_at
          i += 1
        end
        @timer_queue.insert(i, new_timer)
        @selector.wakeup
        new_timer
      end

      def main
        loop do
          break if (@selector.keys.empty? and @timer_queue.empty?) or @exit_mutex.synchronize{ @exit_requested }

          # If there are any timers, schedule a wake-up for when the first
          # timer expires.
          next_timer = @timer_queue.first
          if next_timer
            timeout_millis = (1000 * (next_timer.expire_at - Time.now)).to_i
            timeout_millis = nil if timeout_millis <= 0
          else
            timeout_millis = 0   # sleep indefinitely
          end

          # select(), unless the timeout has already expired
          @selector.select(timeout_millis) if timeout_millis

          # Invoke the callbacks for any expired timers
          now = Time.now
          until @timer_queue.empty? or now < @timer_queue.first.expire_at
            timer = @timer_queue.shift
            timer.send(:callback).call
          end
          timer = nil

          # Handle channels that are ready for I/O operations
          @selector.selectedKeys.to_a.each do |k|
            handle_selection_key(k)
            @selector.selectedKeys.remove(k)
          end
        end
      ensure
        @selector.keys.to_a.each { |k| k.channel.close }    # Close any sockets opened by this EventLoop
        @selector.close
      end

      private

        # Cancel the specified timer.
        def cancel_timer(timer)
          @timer_queue.delete(timer)
          nil
        end

        def handle_selection_key(k)
          att = k.attachment
          case k.channel
          when ServerSocketChannel
            if k.valid? and k.acceptable?
              lw = att[:listening_socket_wrapper]
              accepted = false
              begin
                socket_channel = k.channel.accept
                socket_channel.configureBlocking(false)
                socket_channel.socket.setOOBInline(true)    # Receive TCP URGent data (but not the fact that it's urgent) in-band
                accepted = true
              rescue => e
                # Invoke the on_accept_error callback, if present.
                begin
                  invoke_callback(k.channel, :on_accept_error, e)
                ensure
                  close_channel(k.channel, true)
                end
              end
              if accepted
                cw = ConnectionWrapper.new(self, socket_channel)
                invoke_callback(k.channel, :on_accept, cw)
              end
            end

          when SocketChannel
            if k.valid? and k.connectable?
              cw = att[:connection_wrapper]
              connected = false
              begin
                k.channel.finishConnect
                connected = true
              rescue => e
                # Invoke the on_connect_error callback, if present.
                begin
                  invoke_callback(k.channel, :on_connect_error, e)
                ensure
                  close_channel(k.channel, true)
                end
              end
              if connected
                k.interestOps(k.interestOps & ~SelectionKey::OP_CONNECT)    # We no longer care about connection status
                invoke_callback(k.channel, :on_connect, cw)
              end
            end
            if k.valid? and k.writable?
              bufs = att[:write_buffers]
              callbacks = att[:write_completion_callbacks]
              if bufs and !bufs.empty?
                # Send as much as we can of the list of write buffers
                w = k.channel.write(bufs.to_java(ByteBuffer))

                # Remove the buffers that have been completely sent, and invoke
                # any write-completion callbacks.
                while !bufs.empty? and bufs[0].position == bufs[0].limit
                  bufs.shift
                  callback = callbacks.shift
                  invoke_callback(k.channel, callback)
                end
              elsif (k.interestOps & SelectionKey::OP_WRITE) != 0
                # Socket is writable, but there's nothing here to write.
                # Indicate that we're no longer interested in whether the socket is writable.
                k.interestOps(k.interestOps & ~SelectionKey::OP_WRITE)
              end
            end
            if k.valid? and k.readable?
              @read_buffer.clear
              length = k.channel.read(@read_buffer)
              if length < 0 # connection_closed
                close_channel(k.channel)
              elsif length == 0
                raise "BUG: unhandled length == 0"
              else
                bytes = String.from_java_bytes(@read_buffer.array[0,length])
                invoke_callback(k.channel, :on_receive_bytes, bytes)
              end
            end
          end
        end

        def invoke_callback(channel, callback, *args)
          if callback.is_a?(Symbol)
            callback_proc = channel_callback_hash(channel)[callback]
          else
            callback_proc = callback
          end
          error_callback = channel_callback_hash(channel)[:on_callback_error]
          begin
            callback_proc.call(*args) if callback_proc
          rescue => e
            raise unless error_callback
            error_callback.call(e)
          end
          nil
        end

        def set_callback_error_callback(channel, &callback) # :nodoc:
          channel_callback_hash(channel)[:on_callback_error] = callback
          nil
        end

        def set_on_accept_callback(channel, &callback) # :nodoc:
          channel_callback_hash(channel)[:on_accept] = callback
          k = channel.keyFor(@selector)   # SelectionKey object
          k.interestOps(k.interestOps | SelectionKey::OP_ACCEPT)
          nil
        end

        def set_on_accept_error_callback(channel, &callback) # :nodoc:
          channel_callback_hash(channel)[:on_accept_error] = callback
          k = channel.keyFor(@selector)   # SelectionKey object
          k.interestOps(k.interestOps | SelectionKey::OP_ACCEPT)
          nil
        end

        def set_on_connect_callback(channel, &callback) # :nodoc:
          channel_callback_hash(channel)[:on_connect] = callback
          k = channel.keyFor(@selector)   # SelectionKey object
          k.interestOps(k.interestOps | SelectionKey::OP_CONNECT)    # we want to when the socket is connected or when there are connection errors
          nil
        end

        def set_on_connect_error_callback(channel, &callback) # :nodoc:
          channel_callback_hash(channel)[:on_connect_error] = callback
          k = channel.keyFor(@selector)   # SelectionKey object
          k.interestOps(k.interestOps | SelectionKey::OP_CONNECT)    # we want to when the socket is connected or when there are connection errors
          nil
        end

        def set_on_receive_bytes_callback(channel, &callback) # :nodoc:
          channel_callback_hash(channel)[:on_receive_bytes] = callback
          k = channel.keyFor(@selector)   # SelectionKey object
          k.interestOps(k.interestOps | SelectionKey::OP_READ)    # we want to know when bytes are received
          nil
        end

        def set_on_close_callback(channel, &callback) # :nodoc:
          channel_callback_hash(channel)[:on_close] = callback
          k = channel.keyFor(@selector)   # SelectionKey object
          k.interestOps(k.interestOps | SelectionKey::OP_READ)    # we want to know when the connection is closed
          nil
        end

        def add_to_write_buffer(channel, bytes, &completion_callback) # :nodoc:
          h = channel_callback_hash(channel)
          # Buffer the data to be written
          h[:write_buffers] ||= []
          h[:write_buffers] << ByteBuffer.wrap(bytes.to_java_bytes)

          # Add a write-completion callback, if applicable.
          h[:write_completion_callbacks] ||= []
          h[:write_completion_callbacks] << completion_callback || nil

          # indicate that we want to know when the channel is writable
          k = channel.keyFor(@selector)
          k.interestOps(k.interestOps | SelectionKey::OP_WRITE)
          nil
        end

        def close_channel(channel, error=false)  # :nodoc:
          @selector.wakeup
          h = channel_callback_hash(channel)
          return if h[:already_closed]
          channel.close
          h[:already_closed] = true
          invoke_callback(channel, :on_close) unless error
        end

        def channel_callback_hash(channel) # :nodoc:
          channel.register(@selector, 0) unless channel.keyFor(@selector)
          k = channel.keyFor(@selector)   # SelectionKey object
          k.attach({}) unless k.attachment
          k.attachment
        end

      class SocketChannelWrapper
        def initialize(master, channel) # :nodoc:
          @master = master
          @channel = channel
        end

        def close
          @master.send(:close_channel, @channel)
          nil
        end

        def on_close(&callback)
          @master.send(:set_on_close_callback, @channel, &callback)
          self
        end

        def local_address
          EventLoop.unparse_address(@channel.socket.getLocalSocketAddress)
        end

        protected
      end

      class ListeningSocketWrapper < SocketChannelWrapper
        def on_accept(&callback)
          @master.send(:set_on_accept_callback, @channel, &callback)
          self
        end

        def on_accept_error(&callback)
          @master.send(:set_on_accept_error_callback, @channel, &callback)
          self
        end
      end

      # Connection wrapper object.
      #
      # This object is passed to the block given to EventLoop#on_accept
      class ConnectionWrapper < SocketChannelWrapper
        attr_reader :master
        # Yield to the given block when another callback raises an exception.
        def on_callback_error(&callback)
          @master.send(:set_callback_error_callback, @channel, &callback)
          self
        end
        def on_receive_bytes(&callback)
          @master.send(:set_on_receive_bytes_callback, @channel, &callback)
          self
        end
        def write(bytes, &completion_callback)
          @master.send(:add_to_write_buffer, @channel, bytes, &completion_callback)
          self
        end
        def remote_address
          EventLoop.unparse_address(@channel.socket.getRemoteSocketAddress)
        end
      end

      class OutgoingConnectionWrapper < ConnectionWrapper
        def initialize(master, channel, address)
          @address = address
          super(master, channel)
        end

        def on_connect(&callback)
          @master.send(:set_on_connect_callback, @channel, &callback)
          self
        end

        def on_connect_error(&callback)
          @master.send(:set_on_connect_error_callback, @channel, &callback)
          self
        end
      end

      class Timer
        attr_reader :expire_at
        def initialize(master, expire_at, callback)
          @master = master
          @expire_at = expire_at
          @callback = callback
        end

        def cancel
          @master.send(:cancel_timer, self)
        end

        private
          attr_reader :callback
      end

      # Convert InetSocketAddress to [host, port]
      def self.unparse_address(socket_address)
        return nil unless socket_address
        [socket_address.getAddress.getHostAddress, socket_address.getPort]
      end

      # Convert [host, port] to InetSocketAddress
      def self.parse_address(address)
        return nil unless address
        raise TypeError.new("address must be [host, port], not #{address.inspect}") unless address.length == 2
        host, port = address
        raise TypeError.new("address must be [host, port], not #{address.inspect}") unless host.is_a? String and port.is_a? Integer
        InetSocketAddress.new(host, port)
      end
    end
  end
end
