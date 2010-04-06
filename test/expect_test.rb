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

    # ScripTTY should process bytes received at the same time separately, and buffer if necessary.
    def test_byte_buffering
      # Initialize objects
      e = ScripTTY::Expect.new
      evloop = e.instance_eval("@net")   # the EventLoop object

      # Set up the test server
      bytes_received = ""
      server = evloop.listen(['127.0.0.1', 0])
      server.on_accept do |conn|
        server.close    # Stop accepting new connections after receiving the first connection
        conn.write(
          "Hello world!  This is a test."   # NOTE: The 2 spaces between these sentences are relevant
        )
      end

      # Expect script
      counts = {:hello => 0, :hello2 => 0}
      begin
        begin
          e.set_timeout 10.0    # 10-second timeout
          e.init_term "dg410"
          e.load_screens File.dirname(__FILE__) + "/expect/screens.txt"
          e.connect server.local_address

          e.expect {
            e.on(e.screen(:hello_world)) { counts[:hello] += 1 }
            e.on(e.screen(:hello_world2)) { counts[:hello] += 1 }
            puts "first expect" # DEBUG FIXME
          }
          assert_equal( {:hello => 1, :hello2 => 0}, counts )

          e.expect {
            e.on(e.screen(:hello_world)) { counts[:hello] += 1 }
            e.on(e.screen(:hello_world2)) { counts[:hello] += 1 }
            puts "second expect"  # DEBUG FIXME
          }
          assert_equal( {:hello => 2, :hello2 => 0}, counts )

          e.expect {
            e.on(e.screen(:hello_world)) { counts[:hello] += 1 }
            e.on(e.screen(:hello_world2)) { counts[:hello] += 1 }
            puts "3rd expect" # DEBUG FIXME
          }
          assert_equal( {:hello => 3, :hello2 => 0}, counts )

          e.expect {
            e.on(e.screen(:hello_world)) { counts[:hello] += 1 }
            e.on(e.screen(:hello_world2)) { counts[:hello] += 1 }
            puts "4th expect" # DEBUG FIXME
          }
          assert_equal( {:hello => 3, :hello2 => 1}, counts )
        rescue
          puts e.dump
          raise
        end
      ensure
        e.exit
      end
    end  end
end
