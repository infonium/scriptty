# = Multi-line character buffer
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

module ScripTTY
  class MultilineBuffer
    attr_reader :height   # buffer height (in lines)
    attr_reader :width    # buffer width (in columns)
    attr_reader :content  # contents of the screen buffer (mainly for debugging/testing)
    def initialize(height, width)
      @height = height
      @width = width
      clear!
    end

    # Clear the buffer
    def clear!
      @content = []   # Array of mutable Strings
      @height.times {
        @content << " "*@width
      }
      nil
    end

    # Write a string (or array of strings) to the specified location.
    #
    # row & column are zero-based
    #
    # Returns the characters that were replaced
    def replace_at(row, column, value)
      if value.is_a?(Array)
        orig = []
        value.each_with_index do |string, i|
          orig << replace_at(row+i, column, string)
        end
        orig
      else
        # value is a string
        return nil if row < 0 or row >= height or column < 0 or column >= width # XXX should we raise an exception here?
        orig = @content[row][column,value.length]
        @content[row][column,value.length] = value
        @content[row] = @content[row][0,width]    # truncate to maximum width
        orig
      end
    end

    # Return characters starting at the specified location.
    #
    # The limit parameter specifies the maximum number of bytes to return.
    # If limit is negative, then everything up to the end of the line is returned.
    def get_at(row, column, limit=1)
      return nil if row < 0 or row >= height or column < 0 or column >= width # XXX should we raise an exception here?
      if limit >= 0
        @content[row][column,limit]
      else
        @content[row][column..-1]
      end
    end

    # Scroll the specified rectangle up by the specified number of lines.
    # Return true.
    def scroll_up_region(row0, col0, row1, col1, count)
      scroll_region_vertical(:up, row0, col0, row1, col1, count)
    end

    # Scroll the specified rectangle down by the specified number of lines.
    # Return true.
    def scroll_down_region(row0, col0, row1, col1, count)
      scroll_region_vertical(:down, row0, col0, row1, col1, count)
    end

    def scroll_left_region(row0, col0, row1, col1, count)
      scroll_region_horizontal(:left, row0, col0, row1, col1, count)
    end

    def scroll_right_region(row0, col0, row1, col1, count)
      scroll_region_horizontal(:right, row0, col0, row1, col1, count)
    end

    private

      def scroll_region_vertical(direction, row0, col0, row1, col1, count)  # :nodoc:
        row0, col0, row1, col1, rect_height, rect_width = rect_helper(row0, col0, row1, col1)

        # Clip the count to the rectangle height
        count = [0, [rect_height, count].min].max

        # Split the region into source and destination ranges
        if direction == :up
          dst_rows = (row0..row1-count)
          src_rows = (row0+count..row1)
          intermediate_rows = (dst_rows.end+1..src_rows.begin-1)
        elsif direction == :down
          src_rows = (row0..row1-count)
          dst_rows = (row0+count..row1)
          intermediate_rows = (src_rows.end+1..dst_rows.begin-1)
        else
          raise ArgumentError.new("Invalid direction #{direction.inspect}")
        end

        # Erase any rows that lie between the source and destination rows.
        # If there are no such rows (e.g. if the source and destination rows
        # overlap) this will do nothing.
        intermediate_rows.each do |row|
          replace_at(row, col0, " "*rect_width)
        end

        # Move the region that is <count> rows below the top of the rectangle to
        # the top of the rectangle.  If we're scrolling the entire region off the
        # screen, this will do nothing.
        z = src_rows.zip(dst_rows)
        z.reverse! if direction == :down
        z.each do |src_row, dst_row|
          replace_at dst_row, col0, replace_at(src_row, col0, " "*rect_width)
        end
        nil
      end

      def scroll_region_horizontal(direction, row0, col0, row1, col1, count)  # :nodoc:
        row0, col0, row1, col1, rect_height, rect_width = rect_helper(row0, col0, row1, col1)

        # Clip the count to the rectangle height
        count = [0, [rect_width, count].min].max

        # Split the region into source and destination ranges
        if direction == :left
          dst_cols = (col0..col1-count)
          src_cols = (col0+count..col1)
          intermediate_cols = (dst_cols.end+1..src_cols.begin-1)
        elsif direction == :right
          src_cols = (col0..col1-count)
          dst_cols = (col0+count..col1)
          intermediate_cols = (src_cols.end+1..dst_cols.begin-1)
        else
          raise ArgumentError.new("Invalid direction #{direction.inspect}")
        end

        # Erase any columns that lie between the source and destination columns.
        # If there are no such columns (e.g. if the source and destination columns
        # overlap) this will do nothing.
        intermediate_width = intermediate_cols.end - intermediate_cols.begin + 1
        if intermediate_width > 0
          (row0..row1).each do |row|
            replace_at(row, intermediate_cols.begin, " "*intermediate_width)
          end
        end

        # Move the region that is <count> rows below the top of the rectangle to
        # the top of the rectangle.  If we're scrolling the entire region off the
        # screen, this will do nothing.
        move_width = src_cols.end - src_cols.begin + 1
        if move_width > 0
          (row0..row1).each do |row|
            replace_at row, dst_cols.begin, replace_at(row, src_cols.begin, " "*move_width)
          end
        end
        nil
      end

      def rect_helper(row0, col0, row1, col1) # :nodoc:
        # Sort coordinates
        row0, row1 = row1, row0 if row0 > row1
        col0, col1 = col1, col0 if col0 > col1

        # Clip the rectangle to the screen size
        row0 = [0, [@height-1, row0].min].max
        col0 = [0, [@width-1, col0].min].max
        row1 = [0, [@height-1, row1].min].max
        col1 = [0, [@width-1, col1].min].max

        # Determine the height and width of the rectangle
        rect_height = row1 - row0 + 1
        rect_width = col1 - col0 + 1

        [row0, col0, row1, col1, rect_height, rect_width]
      end
  end
end
