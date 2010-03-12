# = Tests for ScripTTY::Net::EventLoop
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

class EventLoopTest < Test::Unit::TestCase

  if !defined?(Java)

    # This test gets executed when JRuby is not detected
    def test_dummy_no_jruby
      raise LoadError.new("Cannot test ScripTTY::Net::EventLoop: Not running under JRuby")
    end

  else  # defined?(Java)

    require 'scriptty/net/event_loop'
    require 'thread'

    # An listening socket should be closed when the event loop finishes
    def test_listening_socket_gets_closed
      # Create an event loop, bind a socket, then exit the event loop.
      evloop = ScripTTY::Net::EventLoop.new
      bind_addr = evloop.on_accept(['localhost', 0]) { |conn| true }
      evloop.timer(0) { evloop.exit }
      evloop.main

      # Create another event loop, and attempt to connect to the socket.
      connected = false
      evloop = ScripTTY::Net::EventLoop.new
      evloop.on_connect(bind_addr) { |conn| evloop.exit }

      begin
        evloop.main
        flunk "sockets should be closed when event loop exits"
      rescue NativeException => e
        # XXX - We should be able to handle connection errors on a per-connection basis
        assert_match /^java\.net\.ConnectException: Connection refused/, e.message
      end
    end

    # Start two event loops and make them talk to each other
    def test_chatter
      evloop = ScripTTY::Net::EventLoop.new
      expected_logs = {}

      alice_done = bob_done = false   # XXX - We should do graceful TCP shutdown here instead.

      # Alice
      expected_logs[:alice] = [ "accepted", "said hello", "received", "said goodbye", "closed" ]
      alice_log = []
      alice_addr = evloop.on_accept(["localhost", 0]) { |conn|
        alice_log << "accepted"
        conn.write("Hello, my name is Alice.  What is your name?\n") { alice_log << "said hello" }
        buffer = ""
        conn.on_receive_bytes { |bytes|
          alice_log << "received" unless alice_log.last == "received"
          buffer += bytes
          if buffer =~ /\A(My name is ([^.]*)\.)$/
            name = $2
            buffer = "" # this would be buggy if we wanted to do more than this
            conn.write("Goodbye, #{name}!\n") { alice_log << "said goodbye"; conn.close }
          end
        }
        conn.on_close { alice_log << "closed"; alice_done = true; evloop.exit if bob_done }
      }

      # Bob
      expected_logs[:bob] = [ "connected", "received", "said name", "received", "closed" ]
      bob_log = []
      evloop.on_connect(alice_addr) { |conn|
        bob_log << "connected"
        buffer = ""
        conn.on_receive_bytes { |bytes|
          bob_log << "received" unless bob_log.last == "received"
          buffer += bytes
          if buffer =~ /What is your name\?/
            buffer = "" # this would be buggy if we wanted to do more than this
            conn.write("My name is Bob.\n") { bob_log << "said name" }
          end
        }
        conn.on_close { bob_log << "closed"; bob_done = true; evloop.exit if alice_done }
      }

      # Execute
      evloop.main

      # Assertions
      assert_equal(expected_logs, {:alice => alice_log, :bob => bob_log}, "logs not what was expected")
    end

    def test_run_empty
      net = ScripTTY::Net::EventLoop.new
      net.main
    end

    # Test ConnectionWrapper#local_address and ConnectionWrapper#remote_address
    def test_local_and_remote_address
      evloop = ScripTTY::Net::EventLoop.new

      alice_local_addr = nil
      alice_remote_addr = nil
      alice_addr = evloop.on_accept(['localhost', 0]) { |conn|
        alice_local_addr = conn.local_address
        alice_remote_addr = conn.remote_address
        conn.on_close { conn.master.exit }
        conn.close
      }
      bob_local_addr = nil
      bob_remote_addr = nil
      bob_addr = evloop.on_connect(alice_addr) { |conn|
        bob_local_addr = conn.local_address
        bob_remote_addr = conn.remote_address
        conn.close
      }

      evloop.main

      assert_equal alice_addr, alice_local_addr
      assert_equal alice_addr, bob_remote_addr
      assert_equal alice_remote_addr, bob_local_addr
    end

    def test_accept_multiple
      evloop = ScripTTY::Net::EventLoop.new

      # Listen on two different ports (chosen by the operating system)
      alice_accepted = []
      alice_addrs = evloop.on_accept([['localhost', 0], ['localhost', 0]], :multiple => true) { |conn|
        alice_accepted << conn.local_address
        conn.on_close { conn.master.exit if alice_accepted.length == 2 }
        conn.close
      }

      bob_connected = nil
      bob_addr = evloop.on_connect(alice_addrs[0]) { |conn|
        bob_connected = conn.remote_address
        conn.close
      }

      carol_connected = nil
      carol_addr = evloop.on_connect(alice_addrs[1]) { |conn|
        carol_connected = conn.remote_address
        conn.close
      }

      # Execute
      evloop.main

      assert_equal alice_addrs.sort, alice_accepted.sort, "alice should accepted a connection on both ports"
      assert_equal alice_addrs[0], bob_connected, "bob should connect to alice's first port"
      assert_equal alice_addrs[1], carol_connected, "carol should connect to alice's second port"
    end

    def test_timer_works
      evloop = ScripTTY::Net::EventLoop.new
      t0 = Time.now
      evloop.timer(1) { evloop.exit }
      evloop.main
      t1 = Time.now
      delta = t1 - t0
      assert delta >= 1.0, "Timeout too short: #{delta.inspect}"
      assert delta < 5.0, "warning: Timeout too long: #{delta.inspect}"
    end

    def test_timer_cancel
      result = []
      evloop = ScripTTY::Net::EventLoop.new
      c = evloop.timer(0.8) { result << :c }
      b = evloop.timer(0.5) { result << :b }
      a = evloop.timer(0.2) { result << :a; b.cancel }
      evloop.main
      assert_equal [:a, :c], result
    end
  end   # defined?(Java)
end # class
