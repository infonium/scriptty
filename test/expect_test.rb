# = Tests for ScripTTY::Expect
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
require 'scriptty/expect'
require 'scriptty/net/event_loop'

class ExpectTest < Test::Unit::TestCase

  if !defined?(Java)
    # This test gets executed when JRuby is not detected
    def test_dummy_no_jruby
      raise LoadError.new("Cannot test ScripTTY::Expect: Not running under JRuby")
    end

  else  # defined?(Java)

    # Expect#screen should raise an exception if it's passed a block
    #
    # This is to catch incorrect code like this:
    #
    #     expect {
    #       on screen(:foo) { send(".\n") }
    #     }
    #
    # which needs to be written like this (note extra parens):
    #
    #     expect {
    #       on(screen(:foo)) { send(".\n") }
    #     }
    #
    def test_screen_given_block_raises_exception
      e = ScripTTY::Expect.new
      e.load_screens File.dirname(__FILE__) + "/expect/screens.txt"
      exc = nil
      assert_raise ArgumentError do
        begin
          e.screen(:hello_world) { true }
        rescue => exc
          raise
        end
      end
      assert_equal "`screen' method given but does not take a block", exc.message
    end
  end
end
