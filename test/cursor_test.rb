# = Tests for ScripTTY::Cursor
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

require File.dirname(__FILE__) + "/test_helper.rb"
require 'scriptty/cursor'

class CursorTest < Test::Unit::TestCase
  def test_row_column
    c = ScripTTY::Cursor.new
    assert_equal 0, c.row, "initial row value"
    assert_equal 0, c.column, "initial column value"
    assert_equal [0,0], c.pos, "initial pos"
    c.row += 1
    assert_equal 1, c.row, "row after adding 1 to row"
    assert_equal 0, c.column, "column after adding 1 to row"
    assert_equal [1,0], c.pos, "pos after adding 1 to row"
    c.pos = [5,8]
    assert_equal 5, c.row, "row after setting pos to [5,8]"
    assert_equal 8, c.column, "column after setting pos to [5,8]"
    assert_equal [5,8], c.pos, "pos after setting pos to [5,8]"
  end

  # Modifying the array returned by Cursor#pos should not modify the cursor
  def test_pos_should_return_new_array
    c = ScripTTY::Cursor.new
    assert_equal 0, c.row, "initial row value"
    assert_equal 0, c.column, "initial column value"
    assert_equal [0,0], c.pos, "initial pos"
    a = c.pos
    a[0] += 1
    a[1] += 1
    assert_equal 0, c.row, "row should not change"
    assert_equal 0, c.column, "column should not change"
    assert_equal [0,0], c.pos, "pos should not change"
  end
end
