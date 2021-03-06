# = Transcript writer
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

module ScripTTY
  module Util
    module Transcript
      class Writer

        # Set this to non-nil to force the next record to have a specific timestamp
        attr_accessor :override_timestamp

        def initialize(io)
          @io = io
          @start_time = Time.now
          @override_timestamp = nil
          if block_given?
            begin
              yield self
            ensure
              close
            end
          end
        end

        def close
          @io.close
        end

        # Client connection opened
        def client_open(host, port)
          write_event("Copen", host, port.to_s)
        end

        # Server connection opened
        def server_open(host, port)
          write_event("Sopen", host, port.to_s)
        end

        # Log bytes from the client
        def from_client(bytes)
          write_event("C", bytes)
        end

        # Log bytes from the server
        def from_server(bytes)
          write_event("S", bytes)
        end

        # Log event from the client (i.e. bytes parsed into an escape sequence, with an event fired)
        def client_parsed(event, bytes)
          write_event("Cp", event.to_s, bytes)
        end

        # Log event from the server (i.e. bytes parsed into an escape sequence, with an event fired)
        def server_parsed(event, bytes)
          write_event("Sp", event.to_s, bytes)
        end

        # Log server connection close
        def server_close(message)
          write_event("Sx", message)
        end

        # Log client connection close
        def client_close(message)
          write_event("Cx", message)
        end

        # Log informational message
        def info(*args)
          write_event("*", *args)
        end

        # Convenience function: Log an exception object
        def exception(exc)
          klass_name = exc.class.to_s
          if exc.respond_to?(:message)
            message = exc.message.to_s
          else
            message = exc.to_s
          end
          exception_head(klass_name, message)
          exc.backtrace.each do |line|
            exception_backtrace(line)
          end
          nil
        end

        # Log exception - header - class and message
        def exception_head(klass_name, message)
          write_event("EXC", klass_name, message)
        end

        # Log exception - single backtrace line
        def exception_backtrace(line)
          write_event("EX+", line)
        end

        private

          def write_event(type, *args)
            t = @override_timestamp ? @override_timestamp.to_f : (Time.now - @start_time)
            encoded_args = args.map{|a| encode_string(a)}.join(" ")
            @io.write sprintf("[%.03f] %s %s", t, type, encoded_args) + "\n"
            @io.flush if @io.respond_to?(:flush)
            nil
          end

          def encode_string(bytes)
            escaped = bytes.gsub(/\\|"|[^\x20-\x7e]*/mn) { |m|
              m.unpack("C*").map{ |c|
                sprintf("\\%03o", c)
              }.join
            }
            '"' + escaped + '"'
          end
      end
    end
  end
end

