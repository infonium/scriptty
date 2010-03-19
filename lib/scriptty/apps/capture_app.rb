# = Capture app
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
require 'scriptty/util/transcript/writer'
require 'scriptty/term'
require 'logger'
require 'stringio'

module ScripTTY
  module Apps
    class CaptureApp
      attr_reader :term

      def initialize(argv)
        @client_connection = nil
        @server_connection = nil
        @output_file = nil
        @options = parse_options(argv)
        @console_password = ""   # TODO SECURITY FIXME
        @attached_consoles = []
        @net = ScripTTY::Net::EventLoop.new
        @log_stringio = StringIO.new
        @log = Logger.new(@log_stringio)
      end

      def detach_console(console)
        @attached_consoles.delete(console)
      end

      def log_messages
        ([""]*10 + @log_stringio.string.split("\n"))[-10..-1].map{|line| line.sub(/^.*?\]/, '')}
      end

      def main
        @output_file = Util::Transcript::Writer.new(File.open(@options[:output], @options[:append] ? "a" : "w")) if @options[:output]
        @output_file.info("--- Capture started #{Time.now} ---") if @output_file
        @net.on_accept(@options[:console_addrs] || [], :multiple => true) do |conn|
          p = PasswordPrompt.new(conn, "Console password: ")
          p.authenticate { |password| password == @console_password }
          p.on_fail { conn.write("Authentiation failed.\r\n") { conn.close } }
          p.on_success {
            @attached_consoles << Console.new(conn, self)
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

      # Instruct the event loop to exit.
      #
      # Can be invoked by another thread.
      def exit
        @net.exit
      end

      def handle_console_command_entered(cmd)
        case cmd
        when /^'(.*)$/i    # comment
          comment = $1.strip
          @output_file.info("Comment: #{comment}") if @output_file
          log.info("Comment: #{comment}")
        else
          log.warn("Unknown console command: #{cmd}")
        end
        @last_command = cmd
      end

      private

        attr_reader :log

        def handle_client_connected
          connect_to_server
        end

        def handle_server_connected
          @term = ScripTTY::Term.new(@options[:term])
          @term.on_unknown_sequence do |sequence|
            @output_file.info("Unknown escape sequence", sequence) if @output_file
            log.debug("Unknown escape sequence: #{sequence.inspect}")
          end
        end

        def handle_server_connect_error(e)
          @output_file.info("Server connection error #{e}") if @output_file   # TODO - add a separate transcript record
          @client_connection.close if @client_connection
        end

        def handle_client_receive_bytes(bytes)
          return unless @server_connection    # Ignore bytes received from client until server is connected.
          @output_file.from_client(bytes) if @output_file
          @server_connection.write(bytes)
        end

        def handle_server_receive_bytes(bytes)
          return unless @client_connection    # Ignore bytes received from client until server is connected.
          @output_file.from_server(bytes) if @output_file
          @client_connection.write(bytes)
          @term.feed_bytes(bytes)
          @attached_consoles.each { |c| c.refresh! }
        end

        def handle_client_close
          @output_file.client_close("Client connection closed") if @output_file
          @server_connection.close if @server_connection
          @attached_consoles.each { |c| c.refresh! }
        end

        def handle_server_close
          @output_file.server_close("Server connection closed") if @output_file
          @client_connection.close if @client_connection
          @term = nil
        end

        def connect_to_server
          @net.connect(@options[:connect_addr]) do |server_conn|
            server_conn.on_connect_error { |e| handle_server_connect_error(e) }
            server_conn.on_connect {
              @output_file.server_open(*server_conn.remote_address) if @output_file
              @server_connection = server_conn
              handle_server_connected
            }
            server_conn.on_receive_bytes { |bytes| handle_server_receive_bytes(bytes) }
            server_conn.on_close { handle_server_close; @server_connection = nil }
          end
        end

        def parse_options(argv)
          args = argv.dup
          options = {:term => 'xterm'}
          opts = OptionParser.new do |opts|
            opts.banner = "Usage: #{opts.program_name} [options]"
            opts.separator "Stream capture application"
            opts.on("-l", "--listen [HOST]:PORT", "Listen on the specified HOST:PORT") do |optarg|
              addr = parse_hostport(optarg, :allow_empty_host => true, :allow_zero_port => true)
              options[:listen_addrs] ||= []
              options[:listen_addrs] << addr
            end
            opts.on("-c", "--connect HOST:PORT", "Connect to the specified HOST:PORT") do |optarg|
              addr = parse_hostport(optarg)
              options[:connect_addr] = addr
            end
            opts.on("-C", "--console [HOST]:PORT", "Debug console on the specified HOST:PORT") do |optarg|
              addr = parse_hostport(optarg, :allow_empty_host => true, :allow_zero_port => true)
              options[:console_addrs] ||= []
              options[:console_addrs] << addr
            end
            opts.on("-t", "--term NAME", "Terminal to emulate") do |optarg|
              raise ArgumentError.new("Unsupported terminal #{optarg.inspect}") unless ScripTTY::Term::TERMINAL_TYPES.include?(optarg)
              options[:term] = optarg
            end
            opts.on("-o", "--output FILE", "Write transcript to FILE") do |optarg|
              options[:output] = optarg
            end
            opts.on("-a", "--[no-]append", "Append to output file instead of overwriting it") do |optarg|
              options[:append] = optarg
            end
          end
          opts.parse!(args)
          raise ArgumentError.new("No connect-to address specified") unless options[:connect_addr]
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

require 'scriptty/apps/capture_app/password_prompt'
require 'scriptty/apps/capture_app/console'
