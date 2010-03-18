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
    expected = [{
      :name => "simple_pattern",
      :properties => {
        "rectangle" => [3,4,6,8],
        "char_cursor" => "@",
        "char_ignore" => ".",
        "char_field" => "#",
        "text" => %Q!+-----+\n! +
                  %Q!|@.###| ("field1")\n! +
                  %Q!|#.#.#| ("apple", "orange", "banana")\n! +
                  %Q!|##.##| ("foo",)\n! +
                  %Q!|##.##| (,"bar")\n! +
                  %Q!+-----+\n!,
      },
    }]
    assert_equal expected, result
  end

  # Multiple patterns can be specified in a single file
  def test_multiple_patterns
    result = []
    ScripTTY::ScreenPattern::Parser.parse(read_file("multiple_patterns.txt")) do |screen|
      result << screen
    end
    expected = [
      {
        :name => "simple_pattern_1",
        :properties => {
          "rectangle" => [3,4,6,8],
          "char_cursor" => "@",
          "char_ignore" => ".",
          "char_field" => "#",
          "text" => %Q!+-----+\n! +
                    %Q!|@.###| ("field1")\n! +
                    %Q!|#.#.#| ("apple", "orange", "banana")\n! +
                    %Q!|##.##| ("foo",)\n! +
                    %Q!|##.##| (,"bar")\n! +
                    %Q!+-----+\n!,
        },
      },
      {
        :name => "simple_pattern_2",
        :properties => {
          "rectangle" => [0,0,3,4],
          "char_cursor" => "~",
          "char_ignore" => ".",
          "char_field" => "#",
          "text" => %Q!+-----+\n! +
                    %Q!|~:###| ("field1")\n! +
                    %Q!|#.#.#| (,,)\n! +
                    %Q!|Hello|\n! +
                    %Q!|World|\n! +
                    %Q!+-----+\n!,
        },
      },
    ]
    assert_equal expected, result
  end

  # A here-document that's truncated should result in a parse error.
  def test_truncated_heredoc
    result = []
    pattern = read_file("truncated_heredoc.txt")
    assert_raises(ArgumentError, "truncated here-document should result in parse error") do
      ScripTTY::ScreenPattern::Parser.parse(pattern) do |screen|
        result << screen
      end
    end
  end

  # UTF-16 and UTF-8 should parse correctly
  def test_unicode
    expected = [{
      :name => "unicode_pattern",
      :properties => {
        "rectangle" => [3,4,6,8],
        "char_cursor" => "\xe2\x96\x88", # U+2588 FULL BLOCK
        "char_field" => "\xc3\x98",      # U+00D8 LATIN CAPITAL LETTER O WITH STROKE
        "char_ignore" => ".",            # U+002E FULL STOP
        "text" => %Q!+-----+\n! +
                  %Q!|\xe2\x96\x88.\xc3\x98\xc3\x98\xc3\x98| ("field1")\n! +
                  %Q!|\xc3\x98.\xc3\x98.\xc3\x98| ("apple", "orange", "banana")\n! +
                  %Q!|\xc3\x98\xc3\x98.\xc3\x98\xc3\x98| ("foo",)\n! +
                  %Q!|\xc3\x98\xc3\x98.\xc3\x98\xc3\x98| (,"bar")\n! +
                  %Q!+-----+\n!,
      },
    }]
    for filename in %w( utf16bebom_pattern.bin utf16lebom_pattern.bin utf8_pattern.bin utf8_unix_pattern.bin utf8bom_pattern.bin )
      result = []
      ScripTTY::ScreenPattern::Parser.parse(read_file(filename)) do |screen|
        result << screen
      end
      assert_equal expected, result, "#{filename} should parse correctly"
    end
  end

  # Unicode NFC normalization should be performed.  This avoids user confusion if they enter two different representations of the same character.
  def test_nfd_to_nfc_normalization
    expected = [{:name => "test", :properties => {
      "test" => "\xc3\xa7",   # U+00E7 LATIN SMALL LETTER C WITH CEDILLA
    }}]
    input = %Q([test]\ntest: "c\xcc\xa7")   # ASCII "c" followed by U+0327 COMBINING CEDILLA
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
end
