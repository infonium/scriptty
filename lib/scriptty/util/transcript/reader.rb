# = Transcript reader
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

require 'strscan'

module ScripTTY
  module Util
    module Transcript
      # Reader for transcript files
      #
      # === Example
      #
      #  File.open("transcript", "r") do |file|
      #    reader = ScripTTY::Util::Transcript::Reader.new
      #    file.each_line do |line|
      #      timestamp, type, args = reader.parse_line(line)
      #      # ... do stuff here ...
      #    end
      #  end
      #
      class Reader

        OP_TYPES = {
          "Copen" => :client_open,  # client connection opened
          "Sopen" => :server_open,  # server connection opened
          "C" => :from_client,  # bytes from client
          "S" => :from_server,  # bytes from server
          "*" => :info,   # informational message
          "Sx" => :server_close,  # server closed connection
          "Cx" => :client_close,  # server closed connection
          "Sp" => :server_parsed,  # parsed escape sequence from server
          "Cp" => :client_parsed,  # parsed escape sequence from client
        }

        def initialize(io=nil)
          @current_line = 0
          @io = io
        end

        def next_entry
          raise TypeError.new("no I/O object associated with this reader") unless @io
          return nil if @io.eof?
          line = @io.readline
          return nil unless line
          parse_line(line)
        end

        def close
          @io.close if @io
        end

        def parse_line(line)
          @current_line += 1
          unless line =~ /^\[([\d]+(?:\.[\d]+)?)\] (\S+)((?: "(?:[\x20-\x21\x23-\x5b\x5d-\x7e]|\\[0-3][0-7][0-7])*")*)$/
            raise ArgumentError.new("line #{@current_line}: Unable to parse basic structure")
          end
          timestamp, op, raw_args = [$1, $2, $3]
          timestamp = timestamp.to_f
          args = []
          s = StringScanner.new(raw_args.strip)
          until s.eos?
            m = s.scan(/ +/) # skip whitespace between args
            next if m
            m = s.scan /"[^"]*"/
            raise ArgumentError.new("line #{@current_line}: Unable to parse arguments") unless m
            arg = m[1..-2].gsub(/\\[0-7][0-7][0-7]/) { |m| [m[1..-1].to_i(8)].pack("C*") }    # strip quotes and unescape string
            args << arg
          end
          type = OP_TYPES[op]
          raise ArgumentError.new("line #{@current_line}: Unrecognized opcode #{op}") unless type
          if [:client_open, :server_open].include?(type)
            raise ArgumentError.new("line #{@current_line}: Bad port #{args[1].inspect}") unless args[1] =~ /\A(\d+)\Z/m
            args[1] = args[1].to_i
          end
          [timestamp, type, args]
        end
      end
    end
  end
end

