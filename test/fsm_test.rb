# Tests for ScripTTY::Util::FSM
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
require 'scriptty/util/fsm'

class FSMTest < Test::Unit::TestCase

  # Test the basic operation of the FSM.
  def test_simple
    fsm = ScripTTY::Util::FSM.new(:definition => <<-EOF)
      'a' => eh
      'x' => {
        'y' => ex_why
      }
    EOF

    fsm.process("a")
    assert_equal 'a', fsm.input
    assert_equal ['a'], fsm.input_sequence

    fsm.process("x")
    assert_equal 'x', fsm.input
    assert_equal ['x'], fsm.input_sequence

    fsm.process("y")
    assert_equal 'y', fsm.input
    assert_equal ['x', 'y'], fsm.input_sequence
  end

  # The FSM should accept more than just single characters as inputs.
  def test_string_inputs
    fsm = ScripTTY::Util::FSM.new(:definition => <<-EOF)
      "inputs" => {
        "need not" => {
          "be" => {
            "single characters" => dummy
          }
        }
      }
    EOF

    # The FSM should treat inputs as discrete units, not try to split them up
    # into separate characters.
    assert_raise ScripTTY::Util::FSM::NoMatch do
      fsm.process("i")
    end

    # Test with longer words
    fsm.process("inputs")
    fsm.process("need not")
    fsm.process("be")
    fsm.process("single characters")
    assert_equal ["inputs", "need not", "be", "single characters"], fsm.input_sequence
  end

  # Test that the FSM accepts a callback passed as a block to the constructor.
  def test_callback_given_as_block
    result = []
    fsm = ScripTTY::Util::FSM.new(:definition => <<-EOF) { |event, fsm| result << [event, fsm.input_sequence] }
      'a' => eh
      'x' => {
        'y' => ex_why
      }
    EOF
    fsm.process('a')
    assert_equal [[:eh, ['a']]], result

    fsm.process('x')
    assert_equal [[:eh, ['a']]], result

    fsm.process('y')
    assert_equal [[:eh, ['a']], [:ex_why, ['x', 'y']]], result
  end

  # Test that the FSM accepts a callback passed as an option to the constructor.
  def test_callback_given_as_option
    result = []
    callback_proc = Proc.new { |event, fsm| result << [event, fsm.input_sequence] }
    fsm = ScripTTY::Util::FSM.new(:definition => <<-EOF, :callback => callback_proc)
      'a' => eh
      'x' => {
        'y' => ex_why
      }
    EOF
    fsm.process('a')
    assert_equal [[:eh, ['a']]], result

    fsm.process('x')
    assert_equal [[:eh, ['a']]], result

    fsm.process('y')
    assert_equal [[:eh, ['a']], [:ex_why, ['x', 'y']]], result
  end

  def test_intermediate_callback_with_redirect_proc
    callback_class = Class.new do
      attr_accessor :result
      def csi(f)
        f.redirect = lambda {|m| m.input =~ /[\d;]/}
      end
      def sgr(f)
        @result ||= []
        @result << f.input_sequence
      end
      def five(f)
        @result ||= []
        @result << :five
      end
    end
    cb = callback_class.new
    fsm = ScripTTY::Util::FSM.new(:callback => cb, :callback_method => :send, :definition => <<-EOF)
      '\e' => {
        '[' => csi => {
          'm' => sgr
        }
      }
      '5' => five
    EOF
    "\e[33;42m".split("").each {|c| fsm.process(c)}
    fsm.process("5")
    assert_equal [["\e", "[", "3", "3", ";", "4", "2", "m"], :five], cb.result
  end

  def test_intermediate_callback_with_redirect_symbol
    callback_class = Class.new do
      attr_accessor :result
      def csi(f)
        f.redirect = :csi_redirect
      end
      def csi_redirect(f)
        f.input =~ /[\d;]/
      end
      def sgr(f)
        @result ||= []
        @result << f.input_sequence
      end
      def five(f)
        @result ||= []
        @result << :five
      end
    end
    cb = callback_class.new
    fsm = ScripTTY::Util::FSM.new(:callback => cb, :callback_method => :send, :definition => <<-EOF)
      '\e' => {
        '[' => csi => {
          'm' => sgr
        }
      }
      '5' => five
    EOF
    "\e[33;42m".split("").each {|c| fsm.process(c)}
    fsm.process("5")
    assert_equal [["\e", "[", "3", "3", ";", "4", "2", "m"], :five], cb.result
  end

  def test_reset
    fsm = ScripTTY::Util::FSM.new(:definition => <<-EOF)
      'a' => {
        'b' => ab
      }
    EOF
    assert_equal 1, fsm.next_state

    fsm.process("a")
    assert_not_equal 1, fsm.next_state

    fsm.reset!
    assert_equal 1, fsm.next_state

    assert_raise ScripTTY::Util::FSM::NoMatch do
      fsm.process("b")
    end
  end

  def test_reset_during_callback
    callback_class = Class.new do
      attr_accessor :result
      def redirect_true(f)
        @result ||= [] ; @result << :redirect_true
        f.reset!
        true
      end
      def redirect_false(f)
        @result ||= [] ; @result << :redirect_false
        f.reset!
        false
      end
      def x(f)
        @result ||= [] ; @result << :x
      end
    end
    cb = callback_class.new
    fsm = ScripTTY::Util::FSM.new(:callback => cb, :callback_method => :send, :definition => <<-EOF)
      'x' => x
    EOF
    assert_equal 1, fsm.next_state

    cb.result = []
    fsm.redirect = :redirect_true
    fsm.process("x")
    assert_equal [:redirect_true], cb.result
    assert_equal 1, fsm.next_state
    assert_nil fsm.redirect

    cb.result = []
    fsm.redirect = :redirect_false
    fsm.process("x")
    assert_equal [:redirect_false, :x], cb.result
    assert_equal 1, fsm.next_state
    assert_nil fsm.redirect
  end
end
