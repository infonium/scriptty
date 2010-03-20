# = Tests for ScripTTY::Term::DG410::Parser
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

require File.dirname(__FILE__) + "/../../test_helper.rb"
require 'scriptty/term'

class ParserTest < Test::Unit::TestCase
  def setup
    # Tests should pass with $KCODE = "UTF8"
    $KCODE = "UTF8"
  end

  def test_basic
    expected_result = [
      [:t_blink_enable, "\003"],
      [:t_blink_disable, "\004"],
      [:t_proprietary_ack, "\006"],
      [:t_bell, "\007"],
      [:t_window_home, "\010"],
      [:t_new_line, "\n"],
      [:t_erase_end_of_line, "\013"],
      [:t_erase_window, "\014"],
      [:t_carriage_return, "\015"],
      [:t_blink_on, "\016"],
      [:t_blink_off, "\017"],
      [:t_write_window_address, "\020\000\000"],
      [:t_write_window_address, "\020\006\177"],
      [:t_print_window, "\021"],
      [:t_roll_enable, "\022"],
      [:t_roll_disable, "\023"],
      [:t_underscore_on, "\024"],
      [:t_underscore_off, "\025"],
      [:t_cursor_up, "\027"],
      [:t_cursor_right, "\30"],
      [:t_cursor_left, "\031"],
      [:t_cursor_down, "\032"],
      [:t_osc_m, "\033]0M"],
      [:t_osc_m, "\033]1M"],
      [:t_osc_k, "\033]0K"],
      [:t_osc_k, "\033]1K"],
      [:t_dim_on, "\034"],
      [:t_dim_off, "\035"],
      [:t_reverse_video_on, "\036D"],
      [:t_reverse_video_off, "\036E"],
      [:t_reset, "\036FA"],
      [:t_erase_unprotected, "\036FF"],
#      [:t_delete_line, "\036FI"],
#      [:t_set_cursor_type, "\036FQx"],
#      [:t_delete_character, "\036K"],
      [:t_proprietary_escape, "\036~xx\000"],
      [:t_proprietary_escape, "\036~xx\001x"],
      [:t_proprietary_escape, "\036~xx\002xx"],
      [:t_proprietary_escape, "\036~xx\003xxx"],
#      [:t_telnet_will, "\377\373\001"],
#      [:t_telnet_wont, "\377\374\001"],
#      [:t_telnet_do, "\377\375\001"],
#      [:t_telnet_dont, "\377\376\001"],
      [:t_printable, "h"],
      [:t_printable, "e"],
      [:t_printable, "l"],
      [:t_printable, "l"],
      [:t_printable, "o"],
    ]
    result = []
    parser = ScripTTY::Term.class_by_name("dg410").parser_class.new :callback => Proc.new { |event, fsm|
      result << [event, fsm.input_sequence.join]
    }
    # Mash the inputs together, then check that the parser splits them up properly.
    input_string = expected_result.inject(""){|r, e| r += e[1]}
    parser.feed_bytes(input_string)
    assert_equal expected_result, result
  end

  def test_on_unknown_sequence_block
    expected_result = [
      [:t_erase_unprotected, "\036FF"],
      [:t_printable, "o"],
      [:UNKNOWN, "\x85"],
      [:t_printable, "x"],
    ]
    result = []
    parser = ScripTTY::Term.class_by_name("dg410").parser_class.new :callback => Proc.new { |event, fsm|
      result << [event, fsm.input_sequence.join]
    }
    parser.on_unknown_sequence { |seq|
      result << [:UNKNOWN, seq]
    }
    input_string = expected_result.inject(""){|r, e| r += e[1]}
    parser.feed_bytes(input_string)
    assert_equal expected_result, result
  end

  def test_on_unknown_sequence_ignore
    expected_result = [
      [:t_erase_unprotected, "\036FF"],
      [:t_printable, "o"],
      [:UNKNOWN, "\x80"],
      [:t_printable, "x"],
    ]
    result = []
    parser = ScripTTY::Term.class_by_name("dg410").parser_class.new :callback => Proc.new { |event, fsm|
      result << [event, fsm.input_sequence.join]
    }
    parser.on_unknown_sequence :ignore
    input_string = expected_result.inject(""){|r, e| r += e[1]}
    parser.feed_bytes(input_string)
    assert_equal expected_result.reject{|e| e[0] == :UNKNOWN}, result
  end

  def test_on_unknown_sequence_error
    result = []
    parser = ScripTTY::Term.class_by_name("dg410").parser_class.new :callback => Proc.new { |event, fsm|
      result << [event, fsm.input_sequence.join]
    }
    # First iteration: test that :error is the default
    # Second iteration: test that :error works when explicitly specified
    2.times do
      assert_raises ScripTTY::Util::FSM::NoMatch do
        parser.feed_bytes("\x80")
      end
      parser.on_unknown_sequence :error
    end
  end
end
