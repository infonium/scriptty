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
      # XXX - This complicated bit of code demonstrates that test-driven
      # development is not a panacea.  (A cleanup would be grand.)

      # XXX - This code could use a cleanup.  In particular, the interestOps
      # logic should be simplified, because when it's done wrong, we can get
      # into a state where the event loop won't process events from particular
      # channels.

      include_class 'java.net.InetSocketAddress'
      include_class 'java.nio.ByteBuffer'
      include_class 'java.nio.channels.SelectionKey'
      include_class 'java.nio.channels.Selector'
      include_class 'java.nio.channels.ServerSocketChannel'
      include_class 'java.nio.channels.SocketChannel'

      DEBUG = false

      def initialize
        @selector = Selector.open
        @read_buffer = ByteBuffer.allocate(4096)
        @exit_mutex = Mutex.new   # protects
        @exit_requested = false
        @timer_queue = []    # sorted list of timers, in ascending order of expire_at time
        @done = false
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

      # Return true if the event loop is done executing.
      def done?
        @done
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
        # We want OP_ACCEPT here (and later, OP_READ), so that we can tell
        # when the connection is established/dropped, even if the user does
        # not specifiy any on_accept or on_close/on_read_bytes callbacks.
        schan.register(@selector, SelectionKey::OP_ACCEPT)
        selection_key = schan.keyFor(@selector)   # SelectionKey object
        check_glassfish_issue3027(selection_key)
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
        # We want OP_CONNECT here (and OP_READ after the connection is
        # established) so that we can tell when the connection is
        # established/dropped, even if the user does not specifiy any
        # on_connect or on_close/on_read_bytes callbacks.
        chan.register(@selector, SelectionKey::OP_CONNECT)
        selection_key = chan.keyFor(@selector)   # SelectionKey object
        check_glassfish_issue3027(selection_key)
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
      def timer(delay, options={}, &callback)
        raise ArgumentError.new("no block given") unless callback
        new_timer = Timer.new(self, Time.now + delay, callback, options)
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
        raise ArgumentError.new("use the resume method when suspended") if @suspended
        raise ArgumentError.new("Already done") if @done
        loop do
          # Exit if the "exit" method has been invoked.
          break if @exit_mutex.synchronize{ @exit_requested }
          # Exit if there are no active connections and no non-daemon timers
          break if (@selector.keys.empty? and (@timer_queue.empty? or @timer_queue.map{|t| t.daemon?}.all?))

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
          puts "SELECT: to=#{timeout_millis.inspect} kk=#{@selector.keys.to_a.map{|k|k.attachment}.inspect} tt=#{@timer_queue.length}" if DEBUG
          if timeout_millis
            # Return when something happens, or after timeout (if timeout_millis is non-zero)
            @selector.select(timeout_millis)
          else
            # Non-blocking select
            @selector.selectNow
          end
          puts "DONE SELECT" if DEBUG

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

          # Break out of the loop if the suspend method has been invoked.   # TODO - test me
          return :suspended if @suspended
        end
        nil
      ensure
        unless @suspended or @done
          @selector.keys.to_a.each { |k| k.channel.close }    # Close any sockets opened by this EventLoop
          @selector.close
          @done = true
        end
      end

      # Temporarily break out of the event loop.
      #
      # NOTE: Always use the resume method after using this method, since
      # otherwise network connections will hang.  This method is *NOT*
      # thread-safe.
      #
      # To exit the event loop permanently, use the exit method.
      def suspend
        @suspended = true
        @selector.wakeup
      end

      # Resume a
      #
      # Always use the resume method after using this method.
      def resume
        raise ArgumentError.new("not suspended") unless @suspended
        @suspended = false
        main
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
            puts "SELECTED ServerSocketChannel: valid:#{k.valid?} connectable:#{k.connectable?} writable:#{k.writable?} readable:#{k.readable?} interestOps:#{k.interestOps.inspect} readyOps:#{k.readyOps}" if DEBUG
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
                socket_channel.register(@selector, SelectionKey::OP_READ) # Register the channel with the selector
                check_glassfish_issue3027(socket_channel.keyFor(@selector))
                cw = ConnectionWrapper.new(self, socket_channel)
                invoke_callback(k.channel, :on_accept, cw)
              end
            end

          when SocketChannel
            puts "SELECTED SocketChannel: valid:#{k.valid?} connectable:#{k.connectable?} writable:#{k.writable?} readable:#{k.readable?} interestOps:#{k.interestOps.inspect} readyOps:#{k.readyOps}" if DEBUG
            if k.valid? and (k.connectable? or !att[:connect_finished])
              # WORKAROUND: On some platforms (Mac OS X 10.5, Java 1.5.0_22,
              # JRuby 1.4.0) SelectionKey#isConnectable returns 0 when a
              # connection error would occur, so we would never call
              # finishConnect and therefore keep looping infinitely over the
              # select() call.  To work around this, we add this flag to the
              # channel hash and check it, rather than relying on
              # k.connectable? returning true.
              att[:connect_finished] = true
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
                k.interestOps(k.interestOps | SelectionKey::OP_READ)    # Now we care about incoming bytes (and disconnection)
                invoke_callback(k.channel, :on_connect, cw)
              end
            end
            if k.valid? and k.writable?
              puts "WRITABLE #{att.inspect}" if DEBUG
              bufs = att[:write_buffers]
              callbacks = att[:write_completion_callbacks]
              if bufs and !bufs.empty?
                puts "BUFS NOT EMPTY" if DEBUG
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
              # At the end of a graceful close, (half-)close the output of the TCP connection
              if att[:graceful_close] and (!bufs or bufs.empty?)
                puts "SHUTTING DOWN OUTPUT" if DEBUG
                shutdown_output_on_channel(k.channel)
              end
            end
            if k.valid? and k.readable?
              @read_buffer.clear
              length = k.channel.read(@read_buffer)
              if length < 0 # connection shut down (or at least the input is)
                puts "READ length < 0" if DEBUG
                close_channel(k.channel)
              elsif length == 0
                puts "READ length == 0" if DEBUG
                raise "BUG: unhandled length == 0"    # I think this should never happen.
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
          #k.interestOps(k.interestOps | SelectionKey::OP_CONNECT)    # we want to when the socket is connected or when there are connection errors
          #k.interestOps(k.interestOps | SelectionKey::OP_CONNECT | SelectionKey::OP_READ)    # we want to when the socket is connected or when there are connection errors DEBUG FIXME
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

          # we want to know when the connection closes
          k = channel.keyFor(@selector)   # SelectionKey object
          if channel.is_a?(ServerSocketChannel)
            k.interestOps(k.interestOps | SelectionKey::OP_ACCEPT)
          else  # SocketChannel
            k.interestOps(k.interestOps | SelectionKey::OP_READ)
          end
          nil
        end

        def add_to_write_buffer(channel, bytes, &completion_callback) # :nodoc:
          h = channel_callback_hash(channel)

          return if h[:graceful_close]

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

        def shutdown_output_on_channel(channel)  # :nodoc:
          @selector.wakeup
          h = channel_callback_hash(channel)
          return if h[:already_closed] or h[:already_shutdown_output]
          channel.socket.shutdownOutput
          h[:already_shutdown_output] = true
        end

        def close_channel(channel, error=false)  # :nodoc:
          puts "CLOSE_CHANNEL(hard) #{channel.java_class.simple_name}" if DEBUG
          @selector.wakeup
          h = channel_callback_hash(channel)
          return if h[:already_closed]
          channel.close
          h[:already_closed] = true
          invoke_callback(channel, :on_close) unless error
        end

        def close_channel_gracefully(channel)
          puts "CLOSING GRACEFULLY" if DEBUG
          @selector.wakeup
          h = channel_callback_hash(channel)
          return if h[:graceful_close]
          h[:graceful_close] = true

          # The graceful close code is in the channel-is-writable handler (above),
          # so indicate that we care about whether the channel is # writable.
          k = channel.keyFor(@selector)
          k.interestOps(k.interestOps | SelectionKey::OP_WRITE)
        end

        def channel_callback_hash(channel) # :nodoc:
          raise "BUG" unless channel.keyFor(@selector)
          #channel.register(@selector, 0) unless channel.keyFor(@selector)
          k = channel.keyFor(@selector)   # SelectionKey object
          k.attach({}) unless k.attachment
          k.attachment
        end

        # Check for a known issue that sometimes occurs when running under
        # Glassfish.
        def check_glassfish_issue3027(selection_key)
          return unless selection_key.nil?
          message = <<EOF
ERROR: Erroneous Java/Glassfish SocketChannel.keyFor detected"
********************************************************************************
* There is a known bug in the JDK that causes SocketChannel.keyFor to behave
* erroneously under some versions of Glassfish.  (Glassfish versions 2.1.1 and
* 3.0 or later are not affected.)  A possible workaround for v2.0 is to add the
* following to the appropriate section of your Glassfish config/domain.xml
* file:
*
*  <jvm-options>-Dcom.sun.enterprise.server.ss.ASQuickStartup=false</jvm-options>
*
* See the following pages for more information:
*
* - https://glassfish.dev.java.net/issues/show_bug.cgi?id=3027
* - http://docs.sun.com/app/docs/doc/820-4276/knownissuessges?a=view
* - http://bugs.sun.com/view_bug.do?bug_id=6562829
*
********************************************************************************
EOF
          $stderr.puts message
          raise RuntimeError.new("Erroneous Java/Glassfish SocketChannel.keyFor detected.  See the error log and https://glassfish.dev.java.net/issues/show_bug.cgi?id=3027")
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
        def close(options={})
          if options[:hard]
            @master.send(:close_channel, @channel)
          else
            @master.send(:close_channel_gracefully, @channel)
          end
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
        def initialize(master, expire_at, callback, options={})
          @master = master
          @expire_at = expire_at
          @callback = callback
          @daemon = !!options[:daemon]  # if true, we won't hold up the main loop (just like a daemon thread)
        end

        def daemon?
          @daemon
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
