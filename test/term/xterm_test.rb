# = Tests for ScripTTY::Term::XTerm
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

require File.dirname(__FILE__) + "/../test_helper.rb"
require 'scriptty/term/xterm'

class XtermTest < Test::Unit::TestCase

  # Monkey-patch the class so that we can call protected methods that end in an exclamation mark.
  class ::ScripTTY::Term::XTerm # reopen
    def method_missing(s, *args)
      # XXX - This will have to change in Ruby 1.9, where protected_methods returns symbols instead of strings.
      if "#{s}" =~ /!\Z/ and protected_methods.include?("#{s}")
        send(s, *args)
      else
        super
      end
    end
  end

  def test_initial_cursor_position
    s = ScripTTY::Term::XTerm.new(5, 10)
    assert_equal [0,0], s.cursor_pos
  end

  def test_width_height
    s = ScripTTY::Term::XTerm.new(5, 10)
    assert_equal 10, s.width
    assert_equal 5, s.height
  end

  def test_cursor_position
    s = ScripTTY::Term::XTerm.new(5, 10)

    s.cursor_pos = [4,8]
    s.feed_bytes("\e[H")
    assert_equal [0,0], s.cursor_pos

    s.cursor_pos = [4,8]
    s.feed_bytes("\e[4H")
    assert_equal [3,0], s.cursor_pos

    s.cursor_pos = [4,8]
    s.feed_bytes("\e[;4H")
    assert_equal [0,3], s.cursor_pos

    s.cursor_pos = [4,8]
    s.feed_bytes("\e[0;0H")
    assert_equal [0,0], s.cursor_pos

    s.cursor_pos = [4,8]
    s.feed_bytes("\e[1;1H")
    assert_equal [0,0], s.cursor_pos

    s.cursor_pos = [4,8]
    s.feed_bytes("\e[4;5H")
    assert_equal [3,4], s.cursor_pos
  end

  def test_cursor_up
    {"" => 1, "0" => 1, "1" => 1, "2" => 2, "3" => 3}.each_pair do |p,n|
      s = ScripTTY::Term::XTerm.new(5, 10)
      col = 1
      (n..s.height-1).to_a.reverse.each do |row|
        s.cursor_pos = [row,col]
        s.feed_bytes("\e[#{p}A")
        assert_equal [row-n,col], s.cursor_pos, "should move cursor from row #{row} to row #{row-n}"
      end

      assert_equal [0,col], s.cursor_pos, "sanity check"
      s.feed_bytes("\e[#{p}A")
      assert_equal [0,col], s.cursor_pos, "cursor should not move past screen edge"
    end
  end

  def test_cursor_down
    {"" => 1, "0" => 1, "1" => 1, "2" => 2, "3" => 3}.each_pair do |p,n|
      s = ScripTTY::Term::XTerm.new(5, 10)
      col = 1
      (0..s.height-1-n).each do |row|
        s.cursor_pos = [row,col]
        s.feed_bytes("\e[#{p}B")
        assert_equal [row+n,col], s.cursor_pos, "ESC[#{p}B should move cursor from row #{row} to row #{row+n}"
      end

      assert_equal [s.height-1,col], s.cursor_pos, "sanity check"
      s.feed_bytes("\e[#{p}B")
      assert_equal [s.height-1,col], s.cursor_pos, "cursor should not move past screen edge"
    end
  end

  def test_cursor_right
    {"" => 1, "0" => 1, "1" => 1, "2" => 2, "3" => 3}.each_pair do |p,n|
      s = ScripTTY::Term::XTerm.new(5, 10)
      row = 1
      (0..s.width-1-n).each do |col|
        s.cursor_pos = [row,col]
        s.feed_bytes("\e[#{p}C")
        assert_equal [row,col+n], s.cursor_pos, "ESC[#{p}C should move cursor from col #{col} to col #{col+n}"
      end

      assert_equal [row,s.width-1], s.cursor_pos, "sanity check"
      s.feed_bytes("\e[#{p}C")
      assert_equal [row,s.width-1], s.cursor_pos, "cursor should not move past screen edge"
    end
  end

  def test_cursor_left
    {"" => 1, "0" => 1, "1" => 1, "2" => 2, "3" => 3}.each_pair do |p,n|
      s = ScripTTY::Term::XTerm.new(5, 10)
      row = 1
      (n..s.width-1).to_a.reverse.each do |col|
        s.cursor_pos = [row,col]
        s.feed_bytes("\e[#{p}D")
        assert_equal [row,col-n], s.cursor_pos, "ESC[#{p}D should move cursor from col #{col} to col #{col-n}"
      end

      assert_equal [row,0], s.cursor_pos, "sanity check"
      s.feed_bytes("\e[#{p}D")
      assert_equal [row,0], s.cursor_pos, "cursor should not move past screen edge"
    end
  end

  def test_new_line
    s = ScripTTY::Term::XTerm.new(5, 10)

    s.cursor_pos = [0,4]
    s.feed_bytes("\n\n")
    assert_equal [2,0], s.cursor_pos
  end

  def test_carriage_return
    s = ScripTTY::Term::XTerm.new(5, 10)

    s.cursor_pos = [0,4]
    s.feed_bytes("\r\r")
    assert_equal [0,0], s.cursor_pos
  end

  def test_restore_cursor_never_saved
    s = ScripTTY::Term::XTerm.new(5, 10)
    s.cursor_pos = [2, 4]
    s.feed_bytes("\e[u")    # ANSI restore cursor
    assert_equal [0, 0], s.cursor_pos, "ANSI restore cursor should default to home position"

    s.cursor_pos = [2, 4]
    s.feed_bytes("\e8")    # DEC restore cursor
    assert_equal [0, 0], s.cursor_pos, "DEC restore cursor should default to home position"
  end

  def test_save_cursor_restore_cursor
    s = ScripTTY::Term::XTerm.new(5, 10)
    s.cursor_pos = [2, 4]
    s.feed_bytes("\e[s")    # ANSI save cursor

    s.cursor_pos = [0, 0]
    s.feed_bytes("\e[u")    # ANSI restore cursor
    assert_equal [2, 4], s.cursor_pos, "ANSI restore cursor"

    s.cursor_pos = [1, 3]
    s.feed_bytes("\e7")    # DEC save cursor

    s.cursor_pos = [0, 0]
    s.feed_bytes("\e8")    # DEC restore cursor
    assert_equal [1, 3], s.cursor_pos, "DEC restore cursor"
  end

  def test_scroll_up
    before =  [ "aaaaaaaaaa",
                "bbbbbbbbbb",
                "cccccccccc",
                "dddddddddd",
                "eeeeeeeeee" ]

    after =   [ "bbbbbbbbbb",
                "cccccccccc",
                "dddddddddd",
                "eeeeeeeeee",
                "          " ]

    screen_modify_test(before, after, "scroll up on newline") do |s|
      s.cursor_pos = [4,0]
      s.feed_bytes("\n")
    end
  end


  def test_scroll_up_with_scrolling_region
    before =  [ "aaaaaaaaaa",
                "bbbbbbbbbb",
                "cccccccccc",
                "dddddddddd",
                "eeeeeeeeee" ]

    after =   [ "aaaaaaaaaa",
                "cccccccccc",
                "dddddddddd",
                "          ",
                "eeeeeeeeee" ]

    screen_modify_test(before, after) do |s|
      s.cursor_pos = [3,0]
      s.feed_bytes("\e[2;4r")   # set scrolling region
      s.feed_bytes("\n")
    end
  end

  def test_put_char
    before =  [" "*10]*5
    after =   [ "Hello!    ",
                "          ",
                "          ",
                "          ",
                "          " ]

    screen_modify_test(before, after) do |s|
      s.put_char!("x") # cursor not moved forward
      s.put_char!("H", true)
      s.put_char!("e", true)
      s.put_char!("l", true)
      s.put_char!("l", true)
      s.put_char!("o", true)
      s.put_char!("!")
    end
  end

  def test_carriage_return
    before =  [" "*10]*5
    after =   [ "world!    ",
                "          ",
                "          ",
                "          ",
                "          " ]

    screen_modify_test(before, after) do |s|
      s.feed_bytes("hello!\rworld")
    end
  end

  # Test line_feed (no wrapping)
  def test_new_line
    before =  [" "*10]*5
    after =   [ "hello     ",
                "world     ",
                "          ",
                "          ",
                "          " ]
    screen_modify_test(before, after) do |s|
      s.feed_bytes("hello\nworld")
    end
  end

  private

    def screen_modify_test(start_with, expected, message=nil)
      raise "no block given" unless block_given?

      s = ScripTTY::Term::XTerm.new(start_with.length, start_with[0].length)
      s.text = start_with

      # Do the operation
      yield s

      # Compare
      assert_equal expected, s.text, message
    end
end
