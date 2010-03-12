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

      # Listen for TCP connections on a particular address (given as [host, port]),
      # and invoke the given block when a connection is received.
      #
      # If port 0 is specified, the operating system will choose a port.
      #
      # Returns the [host, port] that was bound (unless :multiple was specified)
      #
      # Options:
      # [:multiple]
      #   If true, then the parameter is a list of addresses, and
      #   multiple [host,port] addresses will be returned as an array.
      def on_accept(address, options={}, &callback)
        raise ArgumentError.new("no block given") unless callback
        if options[:multiple]
          # address is actually a list of addresses
          options = options.dup
          options.delete(:multiple)
          return address.map{ |addr| on_accept(addr, options, &callback) }
        end
        bind_address = parse_address(address)
        schan = ServerSocketChannel.open
        schan.configureBlocking(false)
        schan.socket.bind(bind_address)
        schan.register(@selector, SelectionKey::OP_ACCEPT)
        selection_key = schan.keyFor(@selector)   # SelectionKey object
        selection_key.attach({:on_accept => callback})
        unparse_address(schan.socket.getLocalSocketAddress)   # return [host,port] of local socket
      end

      # Initiate a TCP connection to the specified address (given as [host, port])
      # and invoke the given block when a connection is made.
      #
      # Returns the [host, port] that will be connected to.
      def on_connect(address, options={}, &callback)
        raise ArgumentError.new("no block given") unless callback
        connect_address = parse_address(address)
        chan = SocketChannel.open
        chan.configureBlocking(false)
        chan.socket.setOOBInline(true)    # Receive TCP URGent data (but not the fact that it's urgent) in-band
        chan.register(@selector, SelectionKey::OP_CONNECT)
        selection_key = chan.keyFor(@selector)   # SelectionKey object
        selection_key.attach({:on_connect => callback})
        chan.connect(connect_address)
        unparse_address(connect_address)    # Return [host, port] of address that will be connected to.
      end

      def main
        loop do
          break if @selector.keys.empty? or @exit_mutex.synchronize{ @exit_requested }
          @selector.select
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

        # Convert [host, port] to InetSocketAddress
        def parse_address(address)
          raise TypeError.new("address must be [host, port], not #{address.inspect}") unless address.length == 2
          host, port = address
          raise TypeError.new("address must be [host, port], not #{address.inspect}") unless host.is_a? String and port.is_a? Integer
          InetSocketAddress.new(host, port)
        end

        # Convert InetSocketAddress to [host, port]
        def unparse_address(socket_address)
          # NB: duplicated in ConnectionWrapper
          [socket_address.getAddress.getHostAddress, socket_address.getPort]
        end

        def handle_selection_key(k)
          att = k.attachment
          case k.channel
          when ServerSocketChannel
            if k.valid? and k.acceptable?
              socket_channel = k.channel.accept
              socket_channel.configureBlocking(false)
              socket_channel.socket.setOOBInline(true)    # Receive TCP URGent data (but not the fact that it's urgent) in-band
              if att[:on_accept]
                cw = ConnectionWrapper.new(self, socket_channel)
                att[:on_accept].call(cw)
              end
            end

          when SocketChannel
            if k.valid? and k.connectable?
              k.channel.finishConnect
              k.interestOps(k.interestOps & ~SelectionKey::OP_CONNECT)
              if att[:on_connect]
                cw = ConnectionWrapper.new(self, k.channel)
                att[:on_connect].call(cw)
              end
            end
            if k.valid? and k.writable? # TODO FIXME
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
                  callback.call if callback
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
                att[:on_receive_bytes].call(bytes) if att[:on_receive_bytes]
              end
            end
          end
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

        def close_channel(channel)  # :nodoc:
          @selector.wakeup
          k = channel.keyFor(@selector)
          att = k.attachment
          return if att[:already_closed]
          channel.close
          att[:already_closed] = true
          att[:on_close].call if att[:on_close]
        end

        def channel_callback_hash(channel) # :nodoc:
          channel.register(@selector, 0) unless channel.keyFor(@selector)
          k = channel.keyFor(@selector)   # SelectionKey object
          k.attach({}) unless k.attachment
          k.attachment
        end

      # Connection wrapper object.
      #
      # This object is passed to the block given to EventLoop#on_accept
      class ConnectionWrapper
        attr_reader :master
        def initialize(master, channel) # :nodoc:
          @master = master
          @channel = channel
        end
        def on_receive_bytes(&callback)
          @master.send(:set_on_receive_bytes_callback, @channel, &callback)
        end
        def on_close(&callback)
          @master.send(:set_on_close_callback, @channel, &callback)
        end
        def write(bytes, &completion_callback)
          @master.send(:add_to_write_buffer, @channel, bytes, &completion_callback)
          nil
        end
        def close
          @master.send(:close_channel, @channel)
          nil
        end
        def remote_address
          unparse_address(@channel.socket.getRemoteSocketAddress)
        end
        def local_address
          unparse_address(@channel.socket.getLocalSocketAddress)
        end

        private
          # Convert InetSocketAddress to [host, port]
          def unparse_address(socket_address)
            # NB: duplicated in EventLoop
            [socket_address.getAddress.getHostAddress, socket_address.getPort]
          end
      end
    end
  end
end
