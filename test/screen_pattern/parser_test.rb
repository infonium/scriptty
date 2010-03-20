# = Tests for ScripTTY::ScreenPattern::Parser
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
require 'scriptty/screen_pattern/parser'

class ParserTest < Test::Unit::TestCase
  # Test a simple pattern
  def test_simple_pattern
    result = []
    ScripTTY::ScreenPattern::Parser.parse(read_file("simple_pattern.txt")) do |screen|
      result << screen
    end
    offset = [3,4]
    expected = [{
      :name => "simple_pattern",
      :properties => {
        "position" => [0,0],
        "size" => [4,5],
        "cursor_pos" => [0,0],
        "matches" => [
          [[3,2], "X"],
        ],
        "fields" => {
          "field1" => [0,2..4],
          "apple" => [1, 0..0],
          "orange" => [1, 2..2],
          "banana" => [1, 4..4],
          "foo" => [2,0..1],
          "bar" => [3,3..4],
        },
      },
    }]
    assert_equal add_pos(offset, expected), result
  end

  def test_explicit_cursor_position
    result = []
    ScripTTY::ScreenPattern::Parser.parse(read_file("explicit_cursor_pattern.txt")) do |screen|
      result << screen
    end
    offset = [3,4]
    expected = [{
      :name => "simple_pattern",
      :properties => {
        "position" => [0,0],
        "size" => [4,5],
        "cursor_pos" => [1,1],
        "fields" => {
          "field1" => [0,2..4],
          "apple" => [1, 0..0],
          "orange" => [1, 2..2],
          "banana" => [1, 4..4],
          "foo" => [2,0..1],
          "bar" => [3,3..4],
        },
      },
    }]
    assert_equal add_pos(offset, expected), result
  end

  # Multiple patterns can be specified in a single file
  def test_multiple_patterns
    result = []
    ScripTTY::ScreenPattern::Parser.parse(read_file("multiple_patterns.txt")) do |screen|
      result << screen
    end
    expected = [
      add_pos([3,4], {
        :name => "simple_pattern_1",
        :properties => {  # NB: [3,4] added to these properties
          "position" => [0,0],
          "size" => [4,5],
          "cursor_pos" => [0,0],
          "fields" => {
            "field1" => [0,2..4],
            "apple" => [1, 0..0],
            "orange" => [1, 2..2],
            "banana" => [1, 4..4],
            "foo" => [2,0..1],
            "bar" => [3,3..4],
          },
        },
      }),
      {
        :name => "simple_pattern_2",
        :properties => {
          "position" => [0,0],
          "size" => [4,5],
          "cursor_pos" => [0,0],
          "matches" => [
            [[0,1], ":"],
            [[2,0], "Hello"],
            [[3,0], "World"],
          ],
          "fields" => {
            "field1" => [0, 2..4],
          },
        },
      },
      {
        :name => "simple_pattern_3",
        :properties => {
          "position" => [0,0],
          "size" => [4,5],
          "cursor_pos" => [0,0],
          "matches" => [
            [[0,1], ":"],
            [[2,0], "Hello"],
            [[3,0], "World"],
          ],
          "fields" => {
            "field1" => [0, 2..4],
          },
        },
      },
    ]
    assert_equal expected.length, result.length, "lengths do not match"
    expected.zip(result).each do |e, r|
      assert_equal e, r
    end
  end

  # A here-document that's truncated should result in a parse error.
  def test_truncated_heredoc
    result = []
    pattern = read_file("truncated_heredoc.txt")
    e = nil
    assert_raise(ArgumentError, "truncated here-document should result in parse error") do
      begin
        ScripTTY::ScreenPattern::Parser.parse(pattern) do |screen|
          result << screen
        end
      rescue ArgumentError => e   # save exception for assertion below
        raise
      end
    end
    assert_match /^error:line 12: expected: "END", got EOF/, e.message
  end

  # UTF-16 and UTF-8 should parse correctly
  def test_unicode
    expected = [
      add_pos([3,4], {
        :name => "unicode_pattern",
        :properties => {
          "position" => [0,0],
          "size" => [4,5],
          "cursor_pos" => [0,0],
          "fields" => {
            "field1" => [0,2..4],
            "apple" => [1, 0..0],
            "orange" => [1, 2..2],
            "banana" => [1, 4..4],
            "foo" => [2,0..1],
            "bar" => [3,3..4],
          },
        },
      }),
    ]
    for filename in %w( utf16bebom_pattern.bin utf16lebom_pattern.bin utf8_pattern.bin utf8_unix_pattern.bin utf8bom_pattern.bin )
      result = []
      assert_nothing_raised("#{filename} should parse ok") do
        ScripTTY::ScreenPattern::Parser.parse(read_file(filename)) do |screen|
          result << screen
        end
      end
      assert_equal expected, result, "#{filename} should parse correctly"
    end
  end

  # Unicode NFC normalization should be performed.  This avoids user confusion if they enter two different representations of the same character.
  def test_nfd_to_nfc_normalization
    expected = [{
      :name => "test",
      :properties => {
        "position" => [0,0],
        "size" => [1,2],
        "cursor_pos" => [0,1],
      }
    }]
    input = <<EOF
[test]
char_cursor: "c\xcc\xa7"   # ASCII "c" followed by U+0327 COMBINING CEDILLA
char_ignore: "."
text: <<END
+--+
|.\xc3\xa7|   # U+00E7 LATIN SMALL LETTER C WITH CEDILLA
+--+
END
EOF
    result = []
    ScripTTY::ScreenPattern::Parser.parse(input) do |screen|
      result << screen
    end
    assert_equal expected, result, "NFC unicode normalization should work correctly"
  end

  private

    def read_file(basename)
      File.read(File.join(File.dirname(__FILE__), "parser_test", basename))
    end

    def add_pos(offset, arg)
      if arg.is_a?(Array) and arg[0].is_a?(Integer) and arg[1].is_a?(Integer)
        [offset[0]+arg[0], offset[1]+arg[1]]
      elsif arg.is_a?(Array) and arg[0].is_a?(Integer) and arg[1].is_a?(Range)
        [offset[0]+arg[0], offset[1]+arg[1].first..offset[1]+arg[1].last]
      elsif arg.is_a?(Array)
        arg.map{|a| add_pos(offset, a)}
      elsif arg.is_a?(Hash)
        retval = {}
        arg.each_pair do |k,v|
          if k == "size"
            retval[k] = v
          else
            retval[k] = add_pos(offset, v)
          end
        end
        retval
      else
        arg # raise ArgumentError.new("Don't know how to handle #{arg.inspect}")
      end
    end
end
