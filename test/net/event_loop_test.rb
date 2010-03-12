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

    CONNECTION_REFUSE_ADDR = ['localhost', 2]   # address on which connections will be refused

    def test_callback_error_handling_on_connect_error
      result = []
      evloop = ScripTTY::Net::EventLoop.new
      evloop.connect(CONNECTION_REFUSE_ADDR) { |c|
        c.on_callback_error { result << :callback_error }
        c.on_connect_error { |e| raise "FOO" }
      }
      evloop.main
      assert_equal [:callback_error], result
    end

    def test_connect_error_handling
      result = []
      connect_error = nil
      evloop = ScripTTY::Net::EventLoop.new
      evloop.connect(CONNECTION_REFUSE_ADDR) { |c|
        c.on_connect { result << :connect }
        c.on_connect_error { |e| result << :connect_error; connect_error = e }
        c.on_receive_bytes { |bytes| result << [:receive_bytes, bytes] }
        c.on_close { result << :closed }
      }
      evloop.main
      assert_equal [:connect_error], result
      assert_match /^java.net.ConnectException: Connection refused/, connect_error.message
    end

    # An listening socket should be closed when the event loop finishes
    def test_listening_socket_gets_closed
      # Create an event loop, bind a socket, then exit the event loop.
      evloop = ScripTTY::Net::EventLoop.new
      bind_addr = evloop.on_accept(['localhost', 0]){ |conn| true }.local_address
      evloop.timer(0) { evloop.exit }
      evloop.main

      # Create another event loop, and attempt to connect to the socket.
      connected = false
      error = false
      evloop = ScripTTY::Net::EventLoop.new
      evloop.connect(bind_addr) { |c|
        c.on_connect { |conn| evloop.exit }
        c.on_connect_error { |e|
          assert_match /^java\.net\.ConnectException: Connection refused/, e.message
          error = true
        }
      }
      evloop.main
      assert error, "sockets should be closed when event loop exits"
    end

    # Start two sockets and make them talk to each other
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
      }.local_address

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

      server_local_addr = nil
      server_remote_addr = nil
      server = evloop.listen(['localhost', 0])
      server_addr = server.local_address
      server.on_accept { |conn|
        server_local_addr = conn.local_address
        server_remote_addr = conn.remote_address
        conn.close
        server.close
      }

      client_local_addr = nil
      client_remote_addr = nil
      client = evloop.connect(server_addr)
      client.on_connect { |conn|
        client_local_addr = conn.local_address
        client_remote_addr = conn.remote_address
        conn.close
      }

      evloop.main

      assert_equal server_addr, server_local_addr
      assert_equal server_addr, client_remote_addr
      assert_equal server_remote_addr, client_local_addr
    end

    def test_accept_multiple
      evloop = ScripTTY::Net::EventLoop.new

      # Listen on two different ports (chosen by the operating system)
      alice_accepted = []
      alice_addrs = evloop.on_accept([['localhost', 0], ['localhost', 0]], :multiple => true) { |conn|
        alice_accepted << conn.local_address
        conn.on_close { conn.master.exit if alice_accepted.length == 2 }
        conn.close
      }.map{|lw| lw.local_address}

      bob_connected = nil
      bob_addr = evloop.on_connect(alice_addrs[0]) { |conn|
        bob_connected = conn.remote_address
        conn.close
      }.local_address

      carol_connected = nil
      carol_addr = evloop.on_connect(alice_addrs[1]) { |conn|
        carol_connected = conn.remote_address
        conn.close
      }.local_address

      # Execute
      evloop.main

      assert_equal alice_addrs.sort, alice_accepted.sort, "alice should accepted a connection on both ports"
      assert_equal alice_addrs[0], bob_connected, "bob should connect to alice's first port"
      assert_equal alice_addrs[1], carol_connected, "carol should connect to alice's second port"
    end

    # The timer should work, and not be too fast (or too slow).
    def test_timer_works
      evloop = ScripTTY::Net::EventLoop.new
      t0 = Time.now
      evloop.timer(1) { evloop.exit }
      evloop.main
      t1 = Time.now
      delta = t1 - t0
      assert delta >= 1.0, "Timeout too short: #{delta.inspect}"      # This should never fail
      assert delta < 5.0, "warning: Timeout too long: #{delta.inspect}"     # This might fail on a slow machine
    end

    # A timer with a zero-second delay should get executed immediately.
    def test_timer_with_zero_delay
      result = []
      evloop = ScripTTY::Net::EventLoop.new
      evloop.timer(0) { result << :t }
      evloop.main
      assert_equal [:t], result
    end

    # Timers should be able to be cancelled.
    def test_timer_cancel
      result = []
      evloop = ScripTTY::Net::EventLoop.new
      b = nil
      a = evloop.timer(0.00001) { result << :a; b.cancel }
      b = evloop.timer(0.00002) { result << :b }
      c = evloop.timer(0.00003) { result << :c }
      evloop.main
      assert_equal [:a, :c], result
    end
  end   # defined?(Java)
end # class
