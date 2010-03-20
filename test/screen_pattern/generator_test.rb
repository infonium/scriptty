# = Tests for ScripTTY::ScreenPattern::Generator
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
require 'scriptty/screen_pattern/generator'

class GeneratorTest < Test::Unit::TestCase
  def test_simple_pattern
    actual = ScripTTY::ScreenPattern::Generator.generate("foo",
      :size => [3,5],
      :matches => [
        [[0,0], "Hello"],
      ],
      :fields => {
        "one" => [1, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
char_ignore: "."
char_field: "#"
text: <<END
+-----+
|Hello|
|..###| ("one")
|.....|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_field_overlaps_match
    actual = ScripTTY::ScreenPattern::Generator.generate("foo",
      :size => [3,5],
      :matches => [
        [[0,0], "Hello"],
      ],
      :fields => {
        "one" => [0, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
char_ignore: "."
fields: <<END
  ("one", (0, 2), 3)
END
text: <<END
+-----+
|Hello|
|.....|
|.....|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_field_partly_overlaps_match
    actual = ScripTTY::ScreenPattern::Generator.generate("foo",
      :size => [3,5],
      :matches => [
        [[0,0], "abc"],
      ],
      :fields => {
        "one" => [0, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
char_ignore: "."
fields: <<END
  ("one", (0, 2), 3)
END
text: <<END
+-----+
|abc..|
|.....|
|.....|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_field_partly_overlaps_match_with_force_fields
    actual = ScripTTY::ScreenPattern::Generator.generate("foo", :force_fields => true,
      :size => [3,5],
      :matches => [
        [[0,0], "abc"],
      ],
      :fields => {
        "one" => [0, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
char_ignore: "."
char_field: "#"
text: <<END
+-----+
|ab###| ("one")
|.....|
|.....|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_2_adjacent_fields
    actual = ScripTTY::ScreenPattern::Generator.generate("foo",
      :size => [3,5],
      :fields => {
        "one" => [0, 0..1],
        "two" => [0, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
char_ignore: "."
char_field: "#"
fields: <<END
  ("two", (0, 2), 3)
END
text: <<END
+-----+
|##...| ("one")
|.....|
|.....|
+-----+
END
EOT
    assert_equal expected, actual, "When fields are adjacent, the first should be implicit and the second should be explicit"
  end

  def test_3_adjacent_fields
    actual = ScripTTY::ScreenPattern::Generator.generate("foo",
      :size => [3,5],
      :fields => {
        "one" => [0, 0..0],
        "two" => [0, 1..1],
        "three" => [0, 2..3],
      })
    expected = <<EOT
[foo]
size: (3, 5)
char_ignore: "."
char_field: "#"
fields: <<END
  ("two", (0, 1), 1)
END
text: <<END
+-----+
|#.##.| ("one", "three")
|.....|
|.....|
+-----+
END
EOT
    assert_equal expected, actual, "When more than two fields are adjacent, every other one should be explicit"
  end

  def test_simple_pattern_with_cursor
    actual = ScripTTY::ScreenPattern::Generator.generate("foo",
      :size => [3,5],
      :cursor_pos => [1,0],
      :matches => [
        [[0,0], "Hello"],
      ],
      :fields => {
        "one" => [1, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
char_cursor: "@"
char_ignore: "."
char_field: "#"
text: <<END
+-----+
|Hello|
|@.###| ("one")
|.....|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_cursor_overlaps_match
    actual = ScripTTY::ScreenPattern::Generator.generate("foo",
      :size => [3,5],
      :cursor_pos => [0,0],
      :matches => [
        [[0,0], "Hello"],
      ],
      :fields => {
        "one" => [1, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
cursor_pos: (0, 0)
char_ignore: "."
char_field: "#"
text: <<END
+-----+
|Hello|
|..###| ("one")
|.....|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_cursor_overlaps_match_with_force_cursor
    actual = ScripTTY::ScreenPattern::Generator.generate("foo", :force_cursor => true,
      :size => [3,5],
      :cursor_pos => [0,0],
      :matches => [
        [[0,0], "Hello"],
      ],
      :fields => {
        "one" => [1, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
char_cursor: "@"
char_ignore: "."
char_field: "#"
text: <<END
+-----+
|@ello|
|..###| ("one")
|.....|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_force_cursor_regexp_match
    actual = ScripTTY::ScreenPattern::Generator.generate("foo", :force_cursor => /H/,
      :size => [3,5],
      :cursor_pos => [0,0],
      :matches => [
        [[0,0], "Hello"],
      ],
      :fields => {
        "one" => [1, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
char_cursor: "@"
char_ignore: "."
char_field: "#"
text: <<END
+-----+
|@ello|
|..###| ("one")
|.....|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_force_cursor_regexp_nomatch
    actual = ScripTTY::ScreenPattern::Generator.generate("foo", :force_cursor => /x/,
      :size => [3,5],
      :cursor_pos => [0,0],
      :matches => [
        [[0,0], "Hello"],
      ],
      :fields => {
        "one" => [1, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
cursor_pos: (0, 0)
char_ignore: "."
char_field: "#"
text: <<END
+-----+
|Hello|
|..###| ("one")
|.....|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_second_choice_chars
    actual = ScripTTY::ScreenPattern::Generator.generate("foo",
      :size => [3,5],
      :cursor_pos => [1,0],
      :matches => [
        [[0,0], ".@#"],
      ],
      :fields => {
        "one" => [1, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
char_cursor: "+"
char_ignore: "~"
char_field: "*"
text: <<END
+-----+
|.@#~~|
|+~***| ("one")
|~~~~~|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_position_offset
    actual = ScripTTY::ScreenPattern::Generator.generate("foo",
      :position => [1,1],
      :size => [3,5],
      :cursor_pos => [2,1],
      :matches => [
        [[1,1], "Hello"],
      ],
      :fields => {
        "one" => [2, 3..5],
      })
    expected = <<EOT
[foo]
position: (1, 1)
size: (3, 5)
char_cursor: "@"
char_ignore: "."
char_field: "#"
text: <<END
+-----+
|Hello|
|@.###| ("one")
|.....|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_ignore
    actual = ScripTTY::ScreenPattern::Generator.generate("foo",
      :ignore => [[0, 1..1]],
      :size => [3,5],
      :matches => [
        [[0,0], "Hello"],
      ],
      :fields => {
        "one" => [1, 2..4],
      })
    expected = <<EOT
[foo]
size: (3, 5)
char_ignore: "."
char_field: "#"
text: <<END
+-----+
|H.llo|
|..###| ("one")
|.....|
+-----+
END
EOT
    assert_equal expected, actual
  end

  def test_parsed_patterns_raise_no_errors
    require 'scriptty/screen_pattern/parser'
    Dir.glob(File.join(File.dirname(__FILE__), "parser_test", "*_pattern.{txt,bin}")).each do |pathname|
      ScripTTY::ScreenPattern::Parser.parse(File.read(pathname)) do |parsed|
        assert_nothing_raised("parsed #{File.basename(pathname)} should generate successfully") do
          ScripTTY::ScreenPattern::Generator.generate(parsed[:name], parsed[:properties])
        end
      end
    end
  end

end
