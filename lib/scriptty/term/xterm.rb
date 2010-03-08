# = XTerm terminal emulation
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

# TODO - This is incomplete

require 'scriptty/multiline_buffer'
require 'scriptty/cursor'
require 'scriptty/util/fsm'
require 'set'

module ScripTTY # :nodoc:
  module Term # :nodoc:
    class XTerm

      PARSER_DEFINITION = File.read(File.join(File.dirname(__FILE__), "xterm/xterm-escapes.txt"))
      DEFAULT_FLAGS = {
        :insert_mode => false,
        :wraparound_mode => false,
      }.freeze

      # width and height of the display buffer
      attr_reader :width, :height

      def initialize(height=24, width=80)
        @parser_fsm = Util::FSM.new(:definition => PARSER_DEFINITION,
          :callback => self, :callback_method => :send)

        @height = height
        @width = width

        on_unknown_sequence :error
        reset_to_initial_state!
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

      def inspect # :nodoc:
        # The default inspect method shows way too much information.  Simplify it.
        "#<#{self.class.name}:#{sprintf('0x%0x', object_id)} h=#{@height.inspect} w=#{@width.inspect} cursor=#{cursor_pos.inspect}>"
      end

      # Feed the specified byte to the terminal.  Returns a string of
      # bytes that should be transmitted (e.g. for TELNET negotiation).
      def feed_byte(byte)
        raise ArgumentError.new("input should be single byte") unless byte.is_a?(String) and byte.length == 1
        begin
          @parser_fsm.process(byte)
        rescue Util::FSM::NoMatch => e
          @parser_fsm.reset!
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
        bytes.split("").each do |byte|
          retvals << feed_byte(byte)
        end
        retvals.join
      end


      # Return an array of strings representing the lines of text on the screen
      #
      # NOTE: If passing copy=false, do not modify the return value or the strings inside it.
      def text(copy=true)
        if copy
          @glyphs.content.map{|line| line.dup}
        else
          @glyphs.content
        end
      end

      # Return the cursor position, as an array of [row, column].
      #
      # [0,0] represents the topmost, leftmost position.
      def cursor_pos
        [@cursor.row, @cursor.column]
      end

      # Set the cursor position to [row, column].
      #
      # [0,0] represents the topmost, leftmost position.
      def cursor_pos=(v)
        @cursor.pos = v
      end

      # Replace the text on the screen with the specified text.
      #
      # NOTE: This is API is very likely to change in the future.
      def text=(a)
        @glyphs.clear!
        @glyphs.replace_at(0, 0, a)
        a
      end

      protected

        # Reset to the initial state.  Return true.
        def reset_to_initial_state!
          @flags = DEFAULT_FLAGS.dup

          # current cursor position
          @cursor = Cursor.new
          @cursor.row = @cursor.column = 0
          @saved_cursor_position = [0,0]

          # Screen buffer
          @glyphs = MultilineBuffer.new(@height, @width)    # the displayable characters (as bytes)
          @attrs = MultilineBuffer.new(@height, @width)     # character attributes (as bytes)

          # Vertical scrolling region.  An array of [start_row, end_row].  Defaults to [0, height-1].
          @scrolling_region = [0, @height-1]
          true
        end

        # Replace the character under the cursor with the specified character.
        #
        # If curfwd is true, the cursor is also moved forward.
        #
        # Returns true.
        def put_char!(input, curfwd=false)
          raise TypeError.new("input must be single-character string") unless input.is_a?(String) and input.length == 1
          @glyphs.replace_at(@cursor.row, @cursor.column, input)
          @attrs.replace_at(@cursor.row, @cursor.column, " ")
          cursor_forward! if curfwd
          true
        end

        # Move the cursor to the leftmost column in the current row, then return true.
        def carriage_return!
          @cursor.column = 0
          true
        end

        # Move the cursor down one row and return true.
        #
        # If the cursor is on the bottom row of the vertical scrolling region,
        # the region is scrolled.  If bot, but the cursor is on the bottom of
        # the screen, this command has no effect.
        def line_feed!
          if @cursor.row == @scrolling_region[1]   # cursor is on the bottom row of the scrolling region
            scroll_up!
          elsif @cursor.row >= @height-1
            # do nothing
          else
            cursor_down!
          end
          true
        end

        # Save the cursor position.  Return true.
        def save_cursor!
          @saved_cursor_position = [@cursor.row, @cursor.column]
          true
        end

        # Restore the saved cursor position.  If nothing has been saved, then go to the home position.  Return true.
        def restore_cursor!
          @cursor.row, @cursor.column = @saved_cursor_position
          true
        end

        # Move the cursor down one row and return true.
        # If the cursor is on the bottom row, return false without moving the cursor.
        def cursor_down!
          if @cursor.row >= @height-1
            false
          else
            @cursor.row += 1
            true
          end
        end

        # Move the cursor up one row and return true.
        # If the cursor is on the top row, return false without moving the cursor.
        def cursor_up!
          if @cursor.row <= 0
            false
          else
            @cursor.row -= 1
            true
          end
        end

        # Move the cursor right one column and return true.
        # If the cursor is on the right-most column, return false without moving the cursor.
        def cursor_right!
          if @cursor.column >= @width-1
            false
          else
            @cursor.column += 1
            true
          end
        end

        # Move the cursor to the right.  Wrap around if we reach the end of the screen.
        #
        # Return true.
        def cursor_forward!(options={})
          if @cursor.column >= @width-1
            line_feed!
            carriage_return!
          else
            cursor_right!
          end
        end

        # Move the cursor left one column and return true.
        # If the cursor is on the left-most column, return false without moving the cursor.
        def cursor_left!
          if @cursor.column <= 0
            false
          else
            @cursor.column -= 1
            true
          end
        end

        alias cursor_back! cursor_left!   # In the future, this might not be an alias

        # Scroll the contents of the screen up by one row and return true.
        # The position of the cursor does not change.
        def scroll_up!
          @glyphs.scroll_up_region(@scrolling_region[0], 0, @scrolling_region[1], @width-1, 1)
          @attrs.scroll_up_region(@scrolling_region[0], 0, @scrolling_region[1], @width-1, 1)
          true
        end

        # Scroll the contents of the screen down by one row and return true.
        # The position of the cursor does not change.
        def scroll_down!
          @glyphs.scroll_down_region(@scrolling_region[0], 0, @scrolling_region[1], @width-1, 1)
          @attrs.scroll_down_region(@scrolling_region[0], 0, @scrolling_region[1], @width-1, 1)
          true
        end

        # Erase, starting with the character under the cursor and extending to the end of the line.
        # Return true.
        def erase_to_end_of_line!
          @glyphs.replace_at(@cursor.row, @cursor.column, " "*(@width-@cursor.column))
          @attrs.replace_at(@cursor.row, @cursor.column, " "*(@width-@cursor.column))
          true
        end

        # Erase, starting with the beginning of the line and extending to the character under the cursor.
        # Return true.
        def erase_to_start_of_line!
          @glyphs.replace_at(@cursor.row, 0, " "*(@cursor.column+1))
          @attrs.replace_at(@cursor.row, 0, " "*(@cursor.column+1))
          true
        end

        # Erase the current line.  The cursor position is unchanged.
        # Return true.
        def erase_line!
          @glyphs.replace_at(@cursor.row, 0, " "*@width)
          @attrs.replace_at(@cursor.row, 0, " "*@width)
          true
        end

        # Erase the window.  Return true.
        def erase_window!
          empty_line = " "*@width
          @height.times do |row|
            @glyphs.replace_at(row, 0, empty_line)
            @attrs.replace_at(row, 0, empty_line)
          end
          true
        end

        # Delete the specified number of lines, starting at the cursor position
        # extending downwards.  The lines below the deleted lines are scrolled up,
        # and blank lines are inserted below them.
        # Return true.
        def delete_lines!(count=1)
          @glyphs.scroll_up_region(@cursor.row, 0, @height-1, @width-1, count)
          @attrs.scroll_up_region(@cursor.row, 0, @height-1, @width-1, count)
          true
        end

        # Delete the specified number of characters, starting at the cursor position
        # extending to the end of the line.  The characters to the right of the
        # cursor are scrolled left, and blanks are inserted after them.
        # Return true.
        def delete_characters!(count=1)
          @glyphs.scroll_left_region(@cursor.row, @cursor.column, @cursor.row, @width-1, count)
          @attrs.scroll_left_region(@cursor.row, @cursor.column, @cursor.row, @width-1, count)
          true
        end

        # Insert the specified number of blank characters at the cursor position.
        # The characters to the right of the cursor are scrolled right, and blanks
        # are inserted in their place.
        # Return true.
        def insert_blank_characters!(count=1)
          @glyphs.scroll_right_region(@cursor.row, @cursor.column, @cursor.row, @width-1, count)
          @attrs.scroll_right_region(@cursor.row, @cursor.column, @cursor.row, @width-1, count)
          true
        end

        # Insert the specified number of lines characters at the cursor position.
        # The characters to the below the cursor are scrolled down, and blank
        # lines are inserted in their place.
        # Return true.
        def insert_blank_lines!(count=1)
          @glyphs.scroll_down_region(@cursor.row, 0, @height-1, @width-1, count)
          @attrs.scroll_down_region(@cursor.row, 0, @height-1, @width-1, count)
          true
        end

      private

        # Set the vertical scrolling region.
        #
        # Values will be clipped.
        def set_scrolling_region!(top, bottom)
          @scrolling_region[0] = [0, [@height-1, top].min].max
          @scrolling_region[1] = [0, [@width-1, bottom].min].max
          nil
        end

        def error(message)  # XXX - This sucks
          raise ArgumentError.new(message)
          #puts message  # DEBUG FIXME
        end

        def t_reset(fsm)
          reset_to_initial_state!
        end

        # Printable character
        def t_printable(fsm)  # :nodoc:
          insert_blank_characters! if @flags[:insert_mode]  # TODO
          put_char!(fsm.input)
          cursor_forward!
        end

        # Beep
        def t_bell(fsm) end # TODO

        # Backspace
        def t_bs(fsm)
          cursor_back!
          put_char!(" ")
        end

        def t_carriage_return(fsm)
          carriage_return!
        end

        def t_new_line(fsm)
          carriage_return!
          line_feed!
        end

        def t_save_cursor(fsm)
          save_cursor!
        end

        def t_restore_cursor(fsm)
          restore_cursor!
        end

        # ESC [
        def t_parse_csi(fsm)
          fsm.redirect = lambda {|fsm| fsm.input =~ /[\d;]/}
        end

        # ESC [ Ps J
        def t_erase_in_display(fsm)
          (mode,) = parse_csi_params(fsm.input_sequence)
          mode ||= 0   # default is mode 0
          case mode
          when 0
            # Erase from the cursor to the end of the window.  Cursor position is unaffected.
            erase_to_end_of_line!
          when 1
            # Erase the window.  Cursor position is unaffected.
            erase_window!
          when 2
            # Erase the window.  Cursor moves to the home position.
            erase_window!
            @cursor.pos = [0,0]
          else
            # ignored
          end
        end

        # ESC [ ? ... h
        def t_dec_private_mode_set(fsm)
          parse_csi_params(fsm.input_sequence).each do |mode|
            case mode
            when 1   # Application cursor keys
            when 7  # Wraparound mode
              @flags[:wraparound_mode] = true
            when 47   # Use alternate screen buffer
            else
              return error("unknown DEC private mode set (escape sequence: #{fsm.input_sequence.inspect})")
            end
          end
        end

        # ESC [ ? ... l
        def t_dec_private_mode_reset(fsm)
          parse_csi_params(fsm.input_sequence).each do |mode|
            case mode
            when 1   # Normal cursor keys
            when 7  # No wraparound mode
              @flags[:wraparound_mode] = false
            when 47   # Use normal screen buffer
            else
              return error("unknown DEC private mode reset (escape sequence: #{fsm.input_sequence.inspect})")
            end
          end
        end

        # ESC [ Ps; Ps r
        def t_set_scrolling_region(fsm)
          top, bottom = parse_csi_params(fsm.input_sequence)
          top ||= 1
          bottom ||= @height
          @scrolling_region = [top-1, bottom-1]
        end

        # ESC [ Ps K
        def t_erase_in_line(fsm)
          (mode,) = parse_csi_params(fsm.input_sequence)
          mode ||= 0
          case mode
          when 0  # Erase to right
            erase_to_end_of_line!
          when 1  # Erase to left
            erase_to_start_of_line!
          when 2  # Erase all
            erase_line!
          end
        end

        # ESC [ Ps A
        def t_cursor_up(fsm)
          count = parse_csi_params(fsm.input_sequence)[0] || 0
          count = 1 if count < 1
          count.times { cursor_up! }
        end

        # ESC [ Ps B
        def t_cursor_down(fsm)
          count = parse_csi_params(fsm.input_sequence)[0] || 0
          count = 1 if count < 1
          count.times { cursor_down! }
        end

        # ESC [ Ps C
        def t_cursor_right(fsm)
          count = parse_csi_params(fsm.input_sequence)[0] || 0
          count = 1 if count < 1
          count.times { cursor_right! }
        end

        # ESC [ Ps D
        def t_cursor_left(fsm)
          count = parse_csi_params(fsm.input_sequence)[0] || 0
          count = 1 if count < 1
          count.times { cursor_left! }
        end

        # ESC [ Ps ; Ps h
        def t_cursor_position(fsm)
          row, column = parse_csi_params(fsm.input_sequence)
          row ||= 0; column ||= 0     # missing params set to 0
          row -= 1; column -= 1
          row = 0 if row < 0
          column = 0 if column < 0
          row = @height-1 if row >= @height
          column = @width-1 if column >= @width
          @cursor.pos = [row, column]
        end

        # Select graphic rendition
        # ESC [ Pm m
        def t_sgr(fsm)
          params = parse_csi_params(fsm.input_sequence)
          params.each do |param|
            if param.nil?
              # ignore
            elsif param >= 30 and param <= 39
              # TODO - Set foreground colour
            elsif param >= 40 and param <= 49
              # TODO - Set background colour
            else
              # ignore
            end
          end
        end

        # ESC [ Ps c
        def t_send_device_attributes_primary(fsm) end   # XXX TODO - respond with ESC [ ? ...

        # ESC [ > Ps c
        def t_send_device_attributes_secondary(fsm) end   # XXX TODO - respond with ESC [ ? ...

        # ESC [ Ps L
        def t_insert_lines(fsm)
          count = parse_csi_params(fsm.input_sequence)[0] || 1
          insert_blank_lines!(count)
        end

        # ESC [ Ps M
        def t_delete_lines(fsm)
          count = parse_csi_params(fsm.input_sequence)[0] || 1
          delete_lines!(count)
        end

        # ESC [ Ps P
        def t_delete_characters(fsm)
          count = parse_csi_params(fsm.input_sequence)[0] || 1
          delete_characters!(count)
        end

        # ESC [ Ps g
        def t_tab_clear(fsm) end  # TODO

        # ESC H
        def t_tab_set(fsm) end  # TODO

        # ESC =
        def t_application_keypad(fsm) end   # TODO

        # ESC >
        def t_normal_keypad(fsm) end   # TODO

        # ESC [ ... h
        def t_set_mode(fsm)
          parse_csi_params(fsm.input_sequence).each do |mode|
            case mode
            when 4   # Insert mode
              @flags[:insert_mode] = true
            else
              return error("unknown set mode (escape sequence: #{fsm.input_sequence.inspect})")
            end
          end
        end

        # ESC >
        def t_reset_mode(fsm)
          parse_csi_params(fsm.input_sequence).each do |mode|
            case mode
            when 4   # Replace mode
              @flags[:insert_mode] = false
            else
              return error("unknown reset mode (escape sequence: #{fsm.input_sequence.inspect})")
            end
          end
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
          unless seq =~ /\A\e\[\??([\d;]*)[^\d]\Z/
            raise "BUG"
          end
          $1.split(";").map{|p|
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
