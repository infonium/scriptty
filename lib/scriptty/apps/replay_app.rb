# = Fake server that replays transcripts to a client
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
require 'scriptty/net/event_loop'
require 'scriptty/net/console'
require 'scriptty/net/password_prompt'
require 'scriptty/util/transcript/reader'
require 'scriptty/term'
require 'logger'
require 'stringio'

module ScripTTY
  module Apps
    class ReplayApp
      attr_reader :term

      def initialize(argv)
        @client_connection = nil
        @server_connection = nil
        @output_file = nil
        @options = parse_options(argv)
        @console_password = ""   # TODO SECURITY FIXME
        @attached_consoles = []
        @log_stringio = StringIO.new
        @log = Logger.new(@log_stringio)
        @net = ScripTTY::Net::EventLoop.new
        @input_transcript = []
        @last_command = nil
      end

      def detach_console(console)
        @attached_consoles.delete(console)
      end

      def log_messages
        ([""]*10 + @log_stringio.string.split("\n"))[-10..-1].map{|line| line.sub(/^.*?\]/, '')}
      end

      def main
        @output_file = Util::Transcript::Writer.new(File.open(@options[:output], "w")) if @options[:output]
        @net.on_accept(@options[:console_addrs] || [], :multiple => true) do |conn|
          p = ScripTTY::Net::PasswordPrompt.new(conn, "Console password: ")
          p.authenticate { |password| password == @console_password }
          p.on_fail { conn.write("Authentiation failed.\r\n") { conn.close } }
          p.on_success {
            @attached_consoles << ScripTTY::Net::Console.new(conn, self)
            @attached_consoles.each { |c| c.refresh! }
          }
        end
        @net.on_accept(@options[:listen_addrs], :multiple => true) do |conn|
          @output_file.client_open(*conn.remote_address) if @output_file
          @client_connection = conn
          @client_connection.on_receive_bytes { |bytes| handle_client_receive_bytes(bytes) }
          @client_connection.on_close { handle_client_close ; @client_connection = nil }
          handle_client_connected
        end
        @net.main
      ensure
        if @output_file
          @output_file.close
          @output_file = nil
        end
      end

      def handle_console_command_entered(cmd)
        case cmd
        when /^$/   # repeat last command
          if @last_command
            handle_console_command_entered(@last_command)
          else
            log.warn("No previous command entered")
          end
          return nil
        when /^(\d*)(n|next)$/i    # replay next step
          count = $1 ? $1.to_i : 1
          count.times { replay_next }
        else
          log.warn("Unknown console command: #{cmd}")
        end
        @last_command = cmd
      end

      # Instruct the event loop to exit.
      #
      # Can be invoked by another thread.
      def exit
        @net.exit
      end

      private

        attr_reader :log

        def handle_client_connected
          @term = ScripTTY::Term.new(@options[:term])
          @term.on_unknown_sequence do |sequence|
            log.debug("Unknown escape sequence: #{sequence.inspect}")
          end
          replay_start
          replay_next
          refresh_consoles
        end

        def handle_client_receive_bytes(bytes)
          log.info("Received from client: #{bytes.inspect}")
          refresh_consoles
        end

        def handle_client_close
          log.info("Client connection closed")
          refresh_consoles
        end

        def replay_start
          @next_bytes_to_send = nil
          @transcript = []
          @options[:input_files].each do |filename|
            @transcript << ["--- File: #{filename} ---", nil]
            reader = Util::Transcript::Reader.new
            File.open(filename, "r") do |infile|
              line_num = 0
              until infile.eof?
                line_num += 1
                line = infile.readline
                timestamp, type, args = reader.parse_line(line)
                if type == :from_server
                  @transcript << ["(#{line_num}) #{line.strip}", args[0]]
                elsif type == :server_parsed
                  @transcript << ["(#{line_num}) #{line.strip}", args[1]]
                else
                  @transcript << ["(#{line_num}) #{line.strip}", nil]
                end
              end
            end
          end
        end

        def replay_next
          if @next_bytes_to_send
            @client_connection.write(@next_bytes_to_send) { refresh_consoles }
            @term.feed_bytes(@next_bytes_to_send)
            @next_bytes_to_send = nil
          end
          until @transcript.empty?
            display, bytes = @transcript.shift
            if bytes
              log.debug("NXTD: #{display}")   # next data
              @next_bytes_to_send = bytes
              break
            else
              log.debug("INFO: #{display}")
            end
          end
          if @transcript.empty?
            log.debug("DONE")
          end
        end

        def refresh_consoles
          @attached_consoles.each { |c| c.refresh! }
        end

        def parse_options(argv)
          args = argv.dup
          options = {:listen_addrs => [], :console_addrs => []}
          opts = OptionParser.new do |opts|
            opts.banner = "Usage: #{opts.program_name} [options] FILE"
            opts.separator "Stream capture application"
            opts.on("-l", "--listen [HOST]:PORT", "Listen on the specified HOST:PORT") do |optarg|
              addr = parse_hostport(optarg, :allow_empty_host => true, :allow_zero_port => true)
              options[:listen_addrs] << addr
            end
            opts.on("-C", "--console [HOST]:PORT", "Debug console on the specified HOST:PORT") do |optarg|
              addr = parse_hostport(optarg, :allow_empty_host => true, :allow_zero_port => true)
              options[:console_addrs] << addr
            end
            opts.on("-t", "--term NAME", "Terminal to emulate") do |optarg|
              raise ArgumentError.new("Unsupported terminal #{optarg.inspect}") unless ScripTTY::Term::TERMINAL_TYPES.include?(optarg)
              options[:term] = optarg
            end
          end
          opts.parse!(args)
          if args.length < 1
            $stderr.puts "error: No input file(s) specified."
            exit 1
          end
          unless !options[:listen_addrs].empty? and !options[:console_addrs].empty? and options[:term]
            $stderr.puts "error: --listen, --console, and --term are mandatory"
            exit 1
          end
          options[:input_files] = args
          options
        end

        # Parse [HOST:]PORT into separate host and port.  Host is optional, and
        # might be surrounded by square brackets.
        def parse_hostport(s, opts={})
          unless s =~ /\A(\[[^\[\]]*\]|[^\[\]]*):(\d+)\Z/
            raise ArgumentError.new("Unable to parse host:port")
          end
          host, port = [$1, $2]
          host.gsub!(/\A\[(.*?)\]\Z/, '\1')
          port = port.to_i
          raise ArgumentError.new("Invalid port") if port < 0 or port > 0xffff or (port == 0 and !opts[:allow_zero_port])
          unless opts[:allow_empty_host]
            raise ArgumentError.new("Host cannot be empty") if host.empty?
          end
          [host, port]
        end
    end
  end
end
