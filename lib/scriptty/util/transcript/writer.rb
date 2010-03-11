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
        end

        def close
          @io.close
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

        private

          def write_event(type, *args)
            t = @override_timestamp ? @override_timestamp.to_f : (Time.now - @start_time)
            encoded_args = args.map{|a| encode_string(a)}.join(" ")
            @io.write sprintf("[%.03f] %s %s", t, type, encoded_args) + "\n"
            @io.flush if @io.respond_to?(:flush)
            nil
          end

          def encode_string(bytes)
            escaped = bytes.gsub(/\\|"|[^\x20-\x7e]*/m) { |m|
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

