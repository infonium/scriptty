# = Parser for DG410 terminal
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

require 'scriptty/term/dg410'

module ScripTTY # :nodoc:
  module Term
    class DG410 # reopen
      class Parser
        SERVER_PARSER_DEFINITION = File.read(File.join(File.dirname(__FILE__), "dg410-escapes.txt"))
        CLIENT_PARSER_DEFINITION = File.read(File.join(File.dirname(__FILE__), "dg410-client-escapes.txt"))

        # ScripTTY::Util::FSM object used by this parser.  (Used for debugging.)
        attr_reader :fsm

        def initialize(options={})
          @fsm = Util::FSM.new(
            :definition => options[:client] ? CLIENT_PARSER_DEFINITION : SERVER_PARSER_DEFINITION,
            :callback => self, :callback_method => :handle_event)
          @callback = options[:callback]
          @callback_method = options[:callback_method] || :call
          on_unknown_sequence :error
        end

        # Set the behaviour of the terminal when an unknown escape sequence is
        # found.
        #
        # This method takes either a symbol or a block.
        #
        # When a block is given, it is executed whenever an unknown escape
        # sequence is received.  The block is passed the escape sequence as a
        # single string.
        #
        # When a symbol is given, it may be one of the following:
        # [:error]
        #   (default) Raise a ScripTTY::Util::FSM::NoMatch exception.
        # [:ignore]
        #   Ignore the unknown escape sequence.
        def on_unknown_sequence(mode=nil, &block)
          if !block and !mode
            raise ArgumentError.new("No mode specified and no block given")
          elsif block and mode
            raise ArgumentError.new("Block and mode are mutually exclusive, but both were given")
          elsif block
            @on_unknown_sequence = block
          elsif [:error, :ignore].include?(mode)
            @on_unknown_sequence = mode
          else
            raise ArgumentError.new("Invalid mode #{mode.inspect}")
          end
        end

        # Feed the specified byte to the terminal.  Returns a string of
        # bytes that should be transmitted (e.g. for TELNET negotiation).
        def feed_byte(byte)
          raise ArgumentError.new("input should be single byte") unless byte.is_a?(String) and byte.length == 1
          begin
            @fsm.process(byte)
          rescue Util::FSM::NoMatch => e
            @fsm.reset!
            if @on_unknown_sequence == :error
              raise
            elsif @on_unknown_sequence == :ignore
              # do nothing
            elsif !@on_unknown_sequence.is_a?(Symbol)   # @on_unknown_sequence is a Proc
              @on_unknown_sequence.call(e.input_sequence.join)
            else
              raise "BUG"
            end
          end
          ""
        end

        # Convenience method: Feeds several bytes to the terminal.  Returns a
        # string of bytes that should be transmitted (e.g. for TELNET
        # negotiation).
        def feed_bytes(bytes)
          retvals = []
          bytes.split(//n).each do |byte|
            retvals << feed_byte(byte)
          end
          retvals.join
        end

        private

          def handle_event(event, fsm)
            if respond_to?(event, true)
              send(event, fsm)
            else
              @callback.__send__(@callback_method, event, fsm) if @callback
            end
          end

          # Parse proprietary escape code, and fire the :t_proprietary_escape
          # event when finished.
          def t_parse_proprietary_escape(fsm)
            state = 0
            length = nil
            header_length = 5
            fsm.redirect = lambda {|fsm|
              if fsm.input_sequence.length == header_length
                length = fsm.input.unpack("C*")[0]
              end
              if length && fsm.input_sequence.length >= header_length + length
                fsm.redirect = nil
                fsm.fire_event(:t_proprietary_escape)
              end
              true
            }
          end

          # IAC SB ... SE
          def t_parse_telnet_sb(fsm)
            # limit subnegotiation to 100 chars   # FIXME - This is wrong
            count = 0
            fsm.redirect = lambda {|fsm| count += 1; count < 100 && fsm.input_sequence[-2..-1] != ["\377", "\360"]}
          end

          # Parse ANSI/DEC CSI escape sequence parameters.  Pass in fsm.input_sequence
          #
          # Example:
          #   parse_csi_params("\e[H")  # returns []
          #   parse_csi_params("\e[;H")  # returns []
          #   parse_csi_params("\e[2J")  # returns [2]
          #   parse_csi_params("\e[33;42;0m")  # returns [33, 42, 0]
          #   parse_csi_params(["\e", "[", "3", "3", ";", "4" "2", ";" "0", "m"])  # same as above, but takes an array
          #
          # This also works with DEC escape sequences:
          #   parse_csi_params("\e[?1;2J")  # returns [1,2]
          def parse_csi_params(input_seq) # TODO - test this
            seq = input_seq.join if input_seq.respond_to?(:join)  # Convert array to string
            unless seq =~ /\A\e\[\??([\d;]*)[^\d]\Z/n
              raise "BUG"
            end
            $1.split(/;/n).map{|p|
              if p.empty?
                nil
              else
                p.to_i
              end
            }
          end
      end
    end
  end
end
