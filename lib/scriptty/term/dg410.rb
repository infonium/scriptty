# = DG410 terminal emulation
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

# XXX TODO - deduplicate between this and xterm.rb

require 'scriptty/multiline_buffer'
require 'scriptty/cursor'
require 'scriptty/util/fsm'
require 'set'

module ScripTTY # :nodoc:
  module Term
    class DG410
      require 'scriptty/term/dg410/parser'  # we want to create the DG410 class here before parser.rb reopens it

      DEFAULT_FLAGS = {
        :insert_mode => false,
        :wraparound_mode => false,
        :roll_mode => true,   # scroll up when the cursor moves beyond the bottom
      }.freeze

      # width and height of the display buffer
      attr_reader :width, :height

      # Return ScripTTY::Term::DG410::Parser
      def self.parser_class
        Parser
      end

      def initialize(height=24, width=80)
        @parser = self.class.parser_class.new(:callback => self, :callback_method => :send)

        @height = height
        @width = width

        reset_to_initial_state!
      end

      def on_unknown_sequence(mode=nil, &block)
        @parser.on_unknown_sequence(mode, &block)
      end

      def feed_bytes(bytes)
        @parser.feed_bytes(bytes)
      end

      def feed_byte(byte)
        @parser.feed_byte(byte)
      end

      # Return an array of lines of text representing the state of the terminal.
      # Used for debugging.
      def debug_info
        output = []
        output << "state:#{@parser.fsm.state.inspect} seq:#{@parser.fsm.input_sequence && @parser.fsm.input_sequence.join.inspect}"
        output << "scrolling_region: #{@scrolling_region.inspect}"
        output << "flags: roll:#{@flags[:roll_mode]} wraparound:#{@flags[:wraparound_mode]} insert:#{@flags[:insert_mode]}"
        output
      end

      def inspect # :nodoc:
        # The default inspect method shows way too much information.  Simplify it.
        "#<#{self.class.name}:#{sprintf('0x%0x', object_id)} h=#{@height.inspect} w=#{@width.inspect} cursor=#{cursor_pos.inspect}>"
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
            if @flags[:roll_enable]
              scroll_up!
            else
              @cursor.row = @scrolling_region[0]
            end
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

        # Erase the current (or specified) line.  The cursor position is unchanged.
        # Return true.
        def erase_line!(row=nil)
          row = @cursor.row unless row
          @glyphs.replace_at(row, 0, " "*@width)
          @attrs.replace_at(row, 0, " "*@width)
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

        # Move the cursor to the left margin on the current row.
        def t_carriage_return(fsm)
          carriage_return!
        end

        # Move the cursor to the left margin on the next row.
        def t_new_line(fsm)
          carriage_return!
          line_feed!
        end

        # Move cursor to the top-left cell of the window.
        def t_window_home(fsm)
          @cursor.pos = [0,0]
        end

        # Erase all characters starting at the cursor and extending to the end of the window.
        def t_erase_unprotected(fsm)
          # Erase to the end of the current line
          erase_to_end_of_line!
          # Erase subsequent lines to the end of the window.
          (@cursor.row+1..@height-1).each do |row|
            erase_line!(row)
          end
        end

        # Erase all characters starting at the cursor and extending to the end of the line.
        def t_erase_end_of_line(fsm)
          erase_to_end_of_line!
        end

        # Move the cursor to the specified position within the window.
        # <020> <column> <row>
        def t_write_window_address(fsm)
          column, row = fsm.input_sequence[1,2].join.unpack("C*")
          row = @cursor.row if row == 0177    # 0177 == special case: do not change the row
          column = @cursor.column if column == 0177   # 0177 == special case: do not change the column
          column = @width-1 if column > @width-1
          row = @height-1 if row > @height-1
          @cursor.pos = [row, column]
        end

        # Erase all characters in the current window, and move the cursor to
        # the top-left cell of the window.
        def t_erase_window(fsm)
          erase_window!
          @cursor.pos = [0,0]
        end

        def t_cursor_up(fsm)
          cursor_up!
        end

        def t_cursor_down(fsm)
          cursor_down!
        end

        def t_cursor_right(fsm)
          cursor_right!
        end

        def t_cursor_left(fsm)
          cursor_left!
        end

        # ESC ] ... M
        # XXX - What is this?
        def t_osc_m(fsm) end  # TODO
        def t_osc_k(fsm) end  # TODO

        def t_roll_enable(fsm)
          @flags[:roll_mode] = true
        end

        def t_roll_disable(fsm)
          @flags[:roll_mode] = false
        end

        def t_print_window(fsm) end # TODO

        def t_bell(fsm) end # TODO

        def t_blink_enable(fsm) end # TODO
        def t_blink_disable(fsm) end # TODO
        def t_underscore_on(fsm) end # TODO
        def t_underscore_off(fsm) end # TODO
        def t_blink_on(fsm) end # TODO
        def t_blink_off(fsm) end # TODO
        def t_reverse_video_on(fsm) end # TODO
        def t_reverse_video_off(fsm) end # TODO
        def t_dim_on(fsm) end # TODO
        def t_dim_off(fsm) end # TODO
        def t_set_cursor_type(fsm) end # TODO

        def t_telnet_will(fsm) end  # TODO
        def t_telnet_wont(fsm) end  # TODO
        def t_telnet_do(fsm) end  # TODO
        def t_telnet_dont(fsm) end  # TODO
        def t_telnet_subnegotiation(fsm) end  # TODO

        # Proprietary escape code
        # <036> ~ <2-byte-command> <n> <n*bytes>
        def t_proprietary_escape(fsm)
          command = fsm.input_sequence[3,2].join
          payload = fsm.input_sequence[5..-1].join
          #puts "PROPRIETARY ESCAPE: command=#{command.inspect} payload=#{payload.inspect}" # DEBUG FIXME
        end

        # Acknowledgement of proprietary escape sequence.
        # From the server to the client, this is just a single-character ACK
        def t_proprietary_ack(fsm) end  # TODO

    end
  end
end
