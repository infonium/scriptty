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
require 'scriptty/term/xterm'

module ScripTTY
  module Apps
    class CaptureApp
#      attr_accessor :client_connection
#      attr_accessor :server_connection
#      attr_reader :net
      attr_reader :term

      def initialize(argv)
        @client_connection = nil
        @server_connection = nil
        @output_file = nil
        @options = parse_options(argv)
        @client_password = ""   # TODO SECURITY FIXME
        @console_password = ""   # TODO SECURITY FIXME
        @attached_consoles = []
      end

      def detach_console(console)
        @attached_consoles.delete(console)
      end

      def main
        @net = ScripTTY::Net::EventLoop.new
        @net.on_accept(*@options[:console_addrs]) do |conn|
          p = PasswordPrompt.new(conn, "Console password: ")
          p.authenticate { |password| password == @console_password }
          p.on_fail { conn.write("Authentiation failed.\r\n") { conn.close } }
          p.on_success {
            @attached_consoles << Console.new(conn, self)
            @attached_consoles.each { |c| c.refresh! }
          }
        end
        @net.on_accept(*@options[:listen_addrs]) do |conn|
          # NOTE: We don't set @client_connection and call handle_client_connected until the client is authenticated.
          p = PasswordPrompt.new(conn, "Enter password: ")
          p.authenticate { |password| password == @client_password }
          p.on_fail { conn.write("Authentiation failed.\r\n") { conn.close } }
          p.on_success {
            if @authenticated_client_connection
              conn.write("Already connected.\r\n") { conn.close }
            else
              @client_connection = conn
              @client_connection.on_receive_bytes { |bytes| handle_client_receive_bytes(bytes) }
              @client_connection.on_close { handle_client_close ; @client_connection = nil; check_close_output_file }
              handle_client_connected
            end
          }
        end
        @net.main
      end

      private

        def check_close_output_file
          if !@client_connection and !@server_connection and @output_file
            @output_file.close
            @output_file = nil
          end
        end

        def handle_client_connected
          connect_to_server
        end

        def handle_server_connected
          @output_file = OutputFile.new(File.join(@options[:output_dir], Time.now.strftime("%Y-%m-%dT%H_%M_%S") + ".txt"))
          @term = ScripTTY::Term::XTerm.new
          @term.on_unknown_sequence do |sequence|
            @output_file.info("Unknown escape sequence", sequence) if @output_file
            puts "Unknown escape sequence: #{sequence.inspect}" # DEBUG FIXME
          end
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
          @server_connection.close
        end

        def handle_server_close
          @output_file.client_close("Server connection closed") if @output_file
          @client_connection.close
          @term = nil
        end

        def connect_to_server
          @net.on_connect(@options[:connect_addr]) do |server|
            @server_connection = server
            @server_connection.on_receive_bytes { |bytes| handle_server_receive_bytes(bytes) }
            @server_connection.on_close { handle_server_close; @server_connection = nil; check_close_output_file }
            handle_server_connected
          end
        end

        def parse_options(argv)
          args = argv.dup
          options = {}
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
            opts.on("-O", "--output-dir DIRECTORY", "Write capture files to DIRECTORY") do |optarg|
              raise ArgumentError.new("--output-dir may only be specified once") if options[:output_dir]
              options[:output_dir] = optarg
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
require 'scriptty/apps/capture_app/output_file'
