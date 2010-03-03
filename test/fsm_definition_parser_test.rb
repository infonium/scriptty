# Tests for ScripTTY::Util::FSM::DefinitionParser
# Copyright (C) 2010  Infonium Inc
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
require 'scriptty/util/fsm/definition_parser'

class FSMDefinitionParserTest < Test::Unit::TestCase
  # Test that the parser can parse empty definitions, comments, whitespace, etc.
  def test_empty_definitions
    assert_equal [], parse(""), 'empty string'
    assert_equal [], parse("\t  "), 'only whitespace'
    assert_equal [], parse("# This is a comment"), 'comment'
    assert_equal [], parse("   # This is a comment"), 'comment with leading whitespace'
    assert_equal [], parse("\n\n\n"), 'blank lines'
    assert_equal [], parse("\n\n\n    # blah\n"), 'blank lines with comment'
  end

  def test_single_quotes_must_hold_single_characters
    definition = <<-EOF
      'spam' => foo   # correct form is: "spam" => foo
    EOF
    assert_raise ArgumentError do
      parse(definition)
    end
  end

  def test_flat_fsm
    expected = [
      {:state => 1, :input => "a", :next_state => 1, :event_name => "literal_a"},
      {:state => 1, :input => "b", :next_state => 1, :event_name => "literal_b"},
      {:state => 1, :input => :other, :next_state => 1, :event_name => "other"},
    ]
    definition = <<-EOF
      'a' => literal_a
      'b' => literal_b
      * => other
    EOF
    assert_equal normalized(expected), normalized(parse(definition))
  end

  def test_nested_rules
    expected = [
      {:state => 1, :input => "a", :next_state => 2, :event_name => nil},
      {:state => 2, :input => "b", :next_state => 1, :event_name => "handle_a_b"},
      {:state => 2, :input => "c", :next_state => 1, :event_name => "handle_a_c"},
      {:state => 2, :input => :other, :next_state => 1, :event_name => "handle_a_other"},
      {:state => 1, :input => "b", :next_state => 1, :event_name => "handle_b"},
      {:state => 1, :input => "c", :next_state => 3, :event_name => nil},
      {:state => 3, :input => "a", :next_state => 1, :event_name => "handle_c_a"},
    ]
    definition = <<-EOF
      'a' => {
        'b' => handle_a_b
        'c' => handle_a_c
        * => handle_a_other
      }
      'b' => handle_b
      'c' => {
        'a' => handle_c_a
      }
    EOF
    assert_equal normalized(expected), normalized(parse(definition))
  end

  def test_nested_rule_with_comments
    expected = [
      {:state => 1, :input => "a", :next_state => 2, :event_name => nil},
      {:state => 2, :input => "b", :next_state => 1, :event_name => "ab"},
    ]
    definition = <<-EOF
      'a' => {      # comment 1
        'b' => ab   # comment 2
      }             # comment 3
    EOF
    assert_equal normalized(expected), normalized(parse(definition))
  end

  def test_rested_rule_with_intermediate_event_name
    expected = [
      {:state => 1, :input => "a", :next_state => 2, :event_name => "intermediate"},
      {:state => 2, :input => "b", :next_state => 1, :event_name => "ab"},
    ]
    definition = <<-EOF
      'a' => intermediate => {
        'b' => ab
      }
    EOF
    assert_equal normalized(expected), normalized(parse(definition))
  end

  def test_string_inputs
    expected = [
      {:state => 1, :input => "spam", :next_state => 2, :event_name => nil},
      {:state => 2, :input => "spam", :next_state => 3, :event_name => nil},
      {:state => 3, :input => "spam", :next_state => 4, :event_name => nil},
      {:state => 3, :input => :other, :next_state => 1, :event_name => "not_enough_spam"},
      {:state => 4, :input => "egg", :next_state => 1, :event_name => "rations"},
    ]
    definition = <<-EOF
      "spam" => {
        "spam" => {
          "spam" => {
            "egg" => rations
          }
          * => not_enough_spam
        }
      }
    EOF
    assert_equal normalized(expected), normalized(parse(definition))
  end

  # Tabs are not allowed inside quotes.  If you want to match tabs, escape them.
  def test_disallow_tabs_inside_quotes
    assert_raise ArgumentError do
      parse("\"\t\" => foo\n")
    end
    assert_raise ArgumentError do
      parse("'\t' => foo\n")
    end
    assert_nothing_raised do
      parse("'\\t' => foo\n")
    end
  end

  # We should get an error on duplicate rules
  def test_error_on_conflicting_rule
    e = nil
    assert_raise ArgumentError do
      begin
        parse(<<-EOF)
          # Conflicts aren't necessarily obvious
          'b' => foo
          [a-c] => foo
        EOF
      rescue => e
        raise
      end
    end
    assert_match /^rule conflict/, e.message
  end

  # Single-state test of character classes
  def test_character_classes_1state
    expected = [
      {:state => 1, :input => "0", :next_state => 1, :event_name => "foo"},
      {:state => 1, :input => "1", :next_state => 1, :event_name => "foo"},
      {:state => 1, :input => "2", :next_state => 1, :event_name => "foo"},
      {:state => 1, :input => "a", :next_state => 1, :event_name => "foo"},
      {:state => 1, :input => "b", :next_state => 1, :event_name => "foo"},
      {:state => 1, :input => "c", :next_state => 1, :event_name => "foo"},
      {:state => 1, :input => "x", :next_state => 1, :event_name => "foo"},
    ]
    definition = <<-EOF
      [0-2a-cx] => foo
    EOF
    assert_equal normalized(expected), normalized(parse(definition))
  end

  # Test "not" character class
  def test_character_classes_1state_exclude
    expected = []
    (0..255).each { |i|
      next if i == 0x61
      expected << {:state => 1, :input => i.chr, :next_state => 1, :event_name => "foo"}
    }
    definition = <<-EOF
      [^a] => foo
    EOF
    assert_equal normalized(expected), normalized(parse(definition))
  end

  # Multi-state test of character classes
  def test_character_classes_nested
    expected = [
      {:state => 1, :input => "0",    :next_state => 2, :event_name => nil},
      {:state => 1, :input => "1",    :next_state => 2, :event_name => nil},
      {:state => 1, :input => "2",    :next_state => 2, :event_name => nil},
      {:state => 2, :input => "\x1e", :next_state => 1, :event_name => "foo"},
      {:state => 2, :input => "\x1f", :next_state => 1, :event_name => "foo"},
      {:state => 2, :input => " ",    :next_state => 1, :event_name => "foo"},
      {:state => 2, :input => "!",    :next_state => 1, :event_name => "foo"},
      {:state => 2, :input => :other, :next_state => 1, :event_name => "bar"},
    ]
    definition = <<-EOF
      [0-2] => {
        [\x1e-!] => foo
        * => bar
      }
    EOF
    assert_equal normalized(expected), normalized(parse(definition))
  end

  private

    def parse(definition)
      ::ScripTTY::Util::FSM::DefinitionParser.new.parse(definition)
    end

    def normalized(table)
      # Set event_name to nil if missing
      table = table.map{|r| r = r.dup; r[:event_name] ||= nil; r}
      # Sort rows
      table.sort{ |a,b| [a[:state], a[:input].to_s] <=> [b[:state], b[:input].to_s] }
    end
end
