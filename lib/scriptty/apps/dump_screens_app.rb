# = Generates a ScripTTY screen dumps from a transcript
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
require 'scriptty/screen_pattern/generator'
require 'set'
require 'digest/sha2'

module ScripTTY
  module Apps
    class DumpScreensApp
      def initialize(argv)
        @options = parse_options(argv)
      end

      def main
        @term = ScripTTY::Term.new(@options[:term])
        @term.on_unknown_sequence :ignore # DEBUG FIXME
        #@term.on_unknown_sequence do |seq|
        #  puts "Unknown escape sequence: #{seq.inspect}"  # DEBUG FIXME
        #end
        @screen_pattern_digests = Set.new
        @prev_screen = nil
        @next_num = 1
        @output_file = File.open(@options[:output], "w") if @options[:output]
        if @options[:output_dir]
          @output_dir = @options[:output_dir]
          @next_num = Dir.entries(@output_dir).map{|e| e =~ /\Ap(\d+)\.txt\Z/ && $1.to_i }.select{|e| e}.sort.last || 1
        end
        begin
          @options[:input_files].each do |input_filename|
            File.open(input_filename, "r") do |input_file|
              reader = ScripTTY::Util::Transcript::Reader.new(input_file)
              while (entry = reader.next_entry)
                timestamp, type, args = entry
                case type
                when :from_server
                  handle_bytes_from_server(args[0])
                when :server_parsed
                  handle_bytes_from_server(args[1])
                when :from_client
                  handle_bytes_from_client(args[0], timestamp)
                end
              end
            end
          end
        ensure
          @output_file.close if @output_file
          @output_file = nil
        end
      end

      private

        def handle_bytes_from_server(bytes)
          @term.feed_bytes(bytes)
        end

        # When we receive bytes from the client, we output a new screen if the
        # screen hasn't already been generated, and if the screen isn't
        # different only in the way that it would be if the user type a
        # single character into a prompt. (See the too_similar method.)
        def handle_bytes_from_client(bytes, timestamp=nil)
          ts = too_similar
          @prev_screen = { :cursor_pos => @term.cursor_pos, :text => @term.text }
          return if ts
          pattern = generate_screen_pattern
          hexdigest = Digest::SHA256.hexdigest(pattern)
          return if @screen_pattern_digests.include?(hexdigest)
          @screen_pattern_digests << hexdigest
          pattern_name = sprintf("p%d", @next_num)
          @next_num += 1
          if @output_file
            @output_file.puts(generate_screen_pattern(pattern_name))
            @output_file.puts("")
          end
          if @output_dir
            File.open(File.join(@output_dir, pattern_name + ".txt"), "w") do |outfile|
              outfile.puts(generate_screen_pattern(pattern_name))
            end
          end
        end

        # Return the screen pattern generated from the current state of the
        # terminal.
        def generate_screen_pattern(name=nil)
          matches = []
          @term.text.each_with_index do |line, row|
            matches << [[row, 0], line]
          end
          ScreenPattern::Generator.generate(name || "no_name", :force_cursor => / /,
            :size => [@term.height, @term.width],
            :cursor_pos => @term.cursor_pos,
            :ignore => @options[:ignore],
            :matches => matches)
        end

        def too_similar
          return false unless @prev_screen
          prev_row, prev_col = @prev_screen[:cursor_pos]
          prev_text = @prev_screen[:text].map{|line| line.dup}
          current_row, current_col = @term.cursor_pos
          current_text = @term.text
          return false if current_row != prev_row or current_col != prev_col+1
          current_text[prev_row][prev_col..prev_col] = " "
          return (current_text == prev_text)
        end

        def parse_options(argv)
          args = argv.dup
          options = {:term => 'xterm', :input_files => [], :rate => 2}
          opts = OptionParser.new do |opts|
            opts.banner = "Usage: #{opts.program_name} [options] FILE..."
            opts.separator "Dump screens to a file/directory based on one or more transcript files"
            opts.separator ""
            opts.on("-t", "--term NAME", "Terminal to emulate") do |optarg|
              raise ArgumentError.new("Unsupported terminal #{optarg.inspect}") unless ScripTTY::Term::TERMINAL_TYPES.include?(optarg)
              options[:term] = optarg
            end
            opts.on("-O", "--output-dir DIR", "Write output to DIR") do |optarg|
              options[:output_dir] = optarg
            end
            opts.on("-o", "--output FILE", "Write output to FILE") do |optarg|
              options[:output] = optarg
            end
            opts.on("-I", "--ignore ROW,COL,LENGTH", "Always ignore the specified region") do |optarg|
              options[:ignore] ||= []
              row, col, length = optarg.split(",").map{|n|
                raise ArgumentError.new("Illegal --ignore argument: #{optarg}") unless n =~ /\A\d+\Z/ and n.to_i >= 0
                n.to_i
              }
              options[:ignore] << [row, col..col+length]
            end
          end
          opts.parse!(args)
          if args.length < 1
            $stderr.puts "error: No input file(s) specified."
            exit 1
          end
          options[:input_files] = args
          if (!options[:output] and !options[:output_dir]) or !options[:term]
            $stderr.puts "error: --term and --output[-dir] are mandatory"
            exit 1
          end
          options
        end
    end
  end
end
