# = Terminal emulation testing app
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

require 'optparse'
require 'scriptty/term'
require 'scriptty/util/transcript/reader'

module ScripTTY
  module Apps
    class TermTestApp
      def initialize(argv)
        @options = parse_options(argv)
      end

      def log(message)
        @log_buffer << message
        @log_file.puts(message) if @log_file
      end

      def main
        @log_buffer = []
        @log_file = @options[:log] && File.open(@options[:log], "w")
        @term = ScripTTY::Term.new(@options[:term])
        @term.on_unknown_sequence do |seq|
          log "Unknown escape sequence: #{seq.inspect}"
        end
        $stdout.print "\ec" # Reset terminal; clear the screen
        $stdout.flush
        time_multiplier = @options[:rate] > 0 ? 1.0/@options[:rate] : 0
        @options[:input_files].each do |inp|
          File.open(inp[:path], "rb") do |input_file|
            time0 = Time.now
            timestamp0 = timestamp = nil
            reader = Util::Transcript::Reader.new
            until input_file.eof?
              # Read a chunk of the input file
              case inp[:format]
              when :binary
                c = input_file.read(1)
                @term.feed_byte(c)
              when :capture
                timestamp, type, args = reader.parse_line(input_file.readline)
                next unless type == :from_server
                bytes = args[0]

                # Wait until the time specified in the timestamp passes
                timestamp0 = timestamp unless timestamp0   # treat the first timestamp as time 0
                sleep_time = (timestamp-timestamp0)*time_multiplier - (Time.now - time0)
                sleep(sleep_time) if sleep_time > 0

                @term.feed_bytes(bytes)
              else
                raise "BUG: Invalid format: #{inp[:format]}"
              end

              # Output the screen contents
              screen_lines = []
              screen_lines << "Timestamp: #{timestamp}" if timestamp
              screen_lines << "Cursor position: #{@term.cursor_pos.inspect}"
              screen_lines += @term.debug_info if @term.respond_to?(:debug_info)
              screen_lines << "+" + "-"*@term.width + "+"
              @term.text.each do |line|
                screen_lines << "|#{line}|"
              end
              screen_lines << "+" + "-"*@term.width + "+"
              screen_lines << "--- Log ---"
              ([0,@log_buffer.length-10].max..@log_buffer.length-1).each do |i|
                screen_lines << sprintf("%3d: %s", i+1, @log_buffer[i])
              end
              screen_lines << "--- End of log ---"
              screen_lines << ""
              $stdout.puts "\e[H" + screen_lines.map{|line| "\e[2K" + line}.join("\n")
              $stdout.flush
            end
          end
        end
        @log_file.close if @log_file
      end

      private
        def parse_options(argv)
          args = argv.dup
          options = {:term => 'xterm', :input_files => [], :rate => 2}
          opts = OptionParser.new do |opts|
            opts.banner = "Usage: #{opts.program_name} [options]"
            opts.separator "Debug a specified terminal emulator"
            opts.on("-t", "--term NAME", "Terminal to emulate") do |optarg|
              raise ArgumentError.new("Unsupported terminal #{optarg.inspect}") unless ScripTTY::Term::TERMINAL_TYPES.include?(optarg)
              options[:term] = optarg
            end
            opts.on("-b", "--binary-input FILE", "Binary file to read") do |optarg|
              options[:input_files] << {:path => optarg, :format => :binary}
            end
            opts.on("-c", "--capture-input FILE", "Capture-format file to read") do |optarg|
              options[:input_files] << {:path => optarg, :format => :capture}
            end
            opts.on("-r", "--rate RATE", "Playback at the specified rate (0 for infinite; default: #{options[:rate]})") do |optarg|
              options[:rate] = optarg.to_f
            end
            opts.on("-L", "--log FILE", "Write log to FILE") do |optarg|
              options[:log] = optarg
            end
          end
          opts.parse!(args)
          options
        end
    end
  end
end
