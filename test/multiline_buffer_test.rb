# = Tests for ScripTTY::MultilineBuffer
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
require 'scriptty/multiline_buffer'

class MultilineBufferTest < Test::Unit::TestCase
  def test_width_height
    b = ScripTTY::MultilineBuffer.new(24,80)
    assert_equal 24, b.height, "height should be 24 columns"
    assert_equal 80, b.width, "width should be 80 columns"
  end

  def test_starts_blank
    b = ScripTTY::MultilineBuffer.new(5,10)
    expected = [
      " "*10,
      " "*10,
      " "*10,
      " "*10,
      " "*10,
    ]
    assert_equal expected, b.content
  end

  def test_get_replace
    b = ScripTTY::MultilineBuffer.new(5,10)
    # Set up the buffer
    assert_equal " "*10, b.replace_at(0, 0, "0123456789")
    assert_equal " "*10, b.replace_at(1, 0, "ABCDEFGHIJ")
    assert_equal " "*10, b.replace_at(2, 0, "KLMNOPQRST")
    assert_equal " "*10, b.replace_at(3, 0, "UVWXYZabcd")
    assert_equal " "*10, b.replace_at(4, 0, "efghijklmn")

    # Test get_at
    assert_equal "l", b.get_at(4,7), "default limit should be 1"
    assert_equal "NOPQ", b.get_at(2,3,4), "basic get_at"
    assert_equal "lmn", b.get_at(4,7,100), "overflowing length should be truncated"
    assert_equal "lmn", b.get_at(4,7,-1), "negative limit"
  end

  def test_replace_at_array
    b = ScripTTY::MultilineBuffer.new(5,10)
    assert_equal [" "*10]*5, b.replace_at(0, 0, [
      "0123456789",
      "ABCDEFGHIJ",
      "KLMNOPQRST",
      "UVWXYZabcd",
      "efghijklmn",
    ])
  end

  def test_clear
    before =  [ "aaaaaaaaaa",
                "bbbbbbbbbb",
                "cccccccccc",
                "dddddddddd",
                "eeeeeeeeee" ]

    after =   [ "          ",
                "          ",
                "          ",
                "          ",
                "          " ]

    screen_modify_test(before, after) do |b|
      b.clear!
    end
  end

  def test_scroll_up_region_enclosed_1
    before =  [ "aaaaaaaaaa",
                "bbbbbbbbbb",
                "cccccccccc",
                "dddddddddd",
                "eeeeeeeeee" ]

    after =   [ "aaaaaaaaaa",
                "bbcccccbbb",
                "ccdddddccc",
                "dd     ddd",
                "eeeeeeeeee" ]

    screen_modify_test(before, after) do |b|
      b.scroll_up_region( 1,2, 3,6, 1)
    end
  end

  def test_scroll_up_region_enclosed_2
    before =  [ "aaaaaaaaaa",
                "bbbbbbbbbb",
                "cccccccccc",
                "dddddddddd",
                "eeeeeeeeee" ]

    after =   [ "aaaaaaaaaa",
                "bbdddddbbb",
                "cc     ccc",
                "dd     ddd",
                "eeeeeeeeee" ]

    screen_modify_test(before, after) do |b|
      b.scroll_up_region( 1,2, 3,6, 2)
    end
  end

  def test_scroll_down_region_enclosed_1
    before =  [ "aaaaaaaaaa",
                "bbbbbbbbbb",
                "cccccccccc",
                "dddddddddd",
                "eeeeeeeeee" ]

    after =   [ "aaaaaaaaaa",
                "bb     bbb",
                "ccbbbbbccc",
                "ddcccccddd",
                "eeeeeeeeee" ]

    screen_modify_test(before, after) do |b|
      b.scroll_down_region( 1,2, 3,6, 1)
    end
  end

  def test_scroll_down_region_enclosed_2
    before =  [ "aaaaaaaaaa",
                "bbbbbbbbbb",
                "cccccccccc",
                "dddddddddd",
                "eeeeeeeeee" ]

    after =   [ "aaaaaaaaaa",
                "bb     bbb",
                "cc     ccc",
                "ddbbbbbddd",
                "eeeeeeeeee" ]

    screen_modify_test(before, after) do |b|
      b.scroll_down_region( 1,2, 3,6, 2)
    end
  end

  def test_scroll_left_region_enclosed_1
    before =  [ "0123456789",
                "ABCDEFGHIJ",
                "KLMNOPQRST",
                "UVWXYZabcd",
                "efghjijklm" ]

    after =   [ "0123456789",
                "ABDEFG HIJ",
                "KLNOPQ RST",
                "UVXYZa bcd",
                "efghjijklm" ]

    screen_modify_test(before, after) do |b|
      b.scroll_left_region( 1,2, 3,6, 1)
    end
  end

  def test_scroll_left_region_enclosed_3
    before =  [ "0123456789",
                "ABCDEFGHIJ",
                "KLMNOPQRST",
                "UVWXYZabcd",
                "efghjijklm" ]

    after =   [ "0123456789",
                "ABFG   HIJ",
                "KLPQ   RST",
                "UVZa   bcd",
                "efghjijklm" ]

    screen_modify_test(before, after) do |b|
      b.scroll_left_region( 1,2, 3,6, 3)
    end
  end

  def test_scroll_left_down_up_right_region_enclosed_zero
    before =  [ "aaaaaaaaaa",
                "bbbbbbbbbb",
                "cccccccccc",
                "dddddddddd",
                "eeeeeeeeee" ]

    after =   [ "aaaaaaaaaa",
                "bbbbbbbbbb",
                "cccccccccc",
                "dddddddddd",
                "eeeeeeeeee" ]
    screen_modify_test(before, after, "scroll_left_region count=0") do |b|
      b.scroll_left_region( 1,2, 3,6, 0)
    end
    screen_modify_test(before, after, "scroll_down_region count=0") do |b|
      b.scroll_down_region( 1,2, 3,6, 0)
    end
    screen_modify_test(before, after, "scroll_up_region count=0") do |b|
      b.scroll_up_region( 1,2, 3,6, 0)
    end
    screen_modify_test(before, after, "scroll_right_region count=0") do |b|
      b.scroll_right_region( 1,2, 3,6, 0)
    end
  end

  def test_scroll_left_down_up_right_region_enclosed_completely
    before =  [ "aaaaaaaaaa",
                "bbbbbbbbbb",
                "cccccccccc",
                "dddddddddd",
                "eeeeeeeeee" ]

    after =   [ "aaaaaaaaaa",
                "bb     bbb",
                "cc     ccc",
                "dd     ddd",
                "eeeeeeeeee" ]

    # Scroll left
    (5..10).each do |count|
      screen_modify_test(before, after, "scroll_left_region count=#{count}") do |b|
        b.scroll_left_region( 1,2, 3,6, count)
      end
    end

    # Scroll down
    (3..10).each do |count|
      screen_modify_test(before, after, "scroll_down_region count=#{count}") do |b|
        b.scroll_down_region( 1,2, 3,6, count)
      end
    end

    # Scroll up
    (3..10).each do |count|
      screen_modify_test(before, after, "scroll_up_region count=#{count}") do |b|
        b.scroll_up_region( 1,2, 3,6, count)
      end
    end

    # Scroll right
    (5..10).each do |count|
      screen_modify_test(before, after, "scroll_right_region count=#{count}") do |b|
        b.scroll_right_region( 1,2, 3,6, count)
      end
    end
  end
  private

    def screen_modify_test(start_with, expected, message=nil)
      raise "no block given" unless block_given?

      b = ScripTTY::MultilineBuffer.new(start_with.length, start_with[0].length)
      b.replace_at(0, 0, start_with)

      # Do the operation
      yield b

      # Compare
      assert_equal expected, b.content, message
    end
end
