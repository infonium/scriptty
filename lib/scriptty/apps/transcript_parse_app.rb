# = Transcript parsing app
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
require 'scriptty/util/transcript/writer'

module ScripTTY
  module Apps
    class TranscriptParseApp
      def initialize(argv)
        @options = parse_options(argv)
      end

      def main
        File.open(@options[:output], "w") do |output_file|
          @writer = ScripTTY::Util::Transcript::Writer.new(output_file)
          @options[:input_files].each do |input_filename|
            File.open(input_filename, "rb") do |input_file|
              reader = ScripTTY::Util::Transcript::Reader.new
              @last_printable = nil
              parser_class = ScripTTY::Term.class_by_name(@options[:term]).parser_class
              @parser = parser_class.new :callback => Proc.new { |event_name, fsm|
                if event_name == :t_printable
                  # Merge printable character sequences together, rather than writing individual "t_printable" events.
                  @last_printable ||= ""
                  @last_printable += fsm.input_sequence.join
                else
                  flush_printable
                  @writer.server_parsed(event_name, fsm.input_sequence.join)
                end
              }
              @parser.on_unknown_sequence { |seq| @writer.server_parsed("?", seq) }
              until input_file.eof?
                timestamp, type, args = reader.parse_line(input_file.readline)
                @writer.override_timestamp = timestamp
                if type == :from_server
                  @writer.send(type, *args) if @options[:keep]
                  bytes = args[0]
                  @parser.feed_bytes(bytes)
                else
                  @writer.send(type, *args)
                end
              end
              flush_printable
            end
          end
          @writer.close
        end
      end

      private

        def flush_printable
          if @last_printable
            @writer.server_parsed(".", @last_printable)
            @last_printable = nil
          end
        end

        def parse_options(argv)
          args = argv.dup
          options = {:input_files => []}
          opts = OptionParser.new do |opts|
            opts.banner = "Usage: #{opts.program_name} [options] FILE..."
            opts.separator "Parse transcript escape sequences according to a specified terminal emulation,"
            opts.separator 'converting raw "S" transcript entries into parsed "Sp" entries.'

            opts.on("-t", "--term NAME", "Terminal to emulate") do |optarg|
              raise ArgumentError.new("Unsupported terminal #{optarg.inspect}") unless ScripTTY::Term::TERMINAL_TYPES.include?(optarg)
              options[:term] = optarg
            end
            opts.on("-k", "--keep", 'Keep original "S" lines in the transcript') do |optarg|
              options[:keep] = optarg
            end
            opts.on("-o", "--output FILE", "Write output to FILE") do |optarg|
              options[:output] = optarg
            end
          end
          opts.parse!(args)
          if args.length < 1
            $stderr.puts "error: No input file(s) specified."
            exit 1
          end
          unless options[:output] and options[:term]
            $stderr.puts "error: --output and --term are mandatory"
            exit 1
          end
          options[:input_files] = args
          options
        end
    end
  end
end
