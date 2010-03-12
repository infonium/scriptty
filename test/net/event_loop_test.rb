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
      t = Thread.new { evloop.main }
      evloop.exit
      t.join

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
      expected_logs = {}

      # Alice
      expected_logs[:alice] = [ "accepted", "said hello", "received", "said goodbye", "closed" ]
      alice_log = []
      alice = ScripTTY::Net::EventLoop.new
      alice_addr = alice.on_accept(["localhost", 0]) { |conn|
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
        conn.on_close { alice_log << "closed"; alice.exit }
      }

      # Bob
      expected_logs[:bob] = [ "connected", "received", "said name", "received", "closed" ]
      bob_log = []
      bob = ScripTTY::Net::EventLoop.new
      bob.on_connect(alice_addr) { |conn|
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
        conn.on_close { bob_log << "closed"; bob.exit }
      }

      # Execute
      thread_status = run_threads(:alice => alice, :bob => bob)

      # Assertions
      assert_equal(expected_logs, {:alice => alice_log, :bob => bob_log}, "logs not what was expected")
      assert_thread_status(thread_status)
    end

    def test_run_empty
      net = ScripTTY::Net::EventLoop.new
      net.main
    end

    # Test ConnectionWrapper#local_address and ConnectionWrapper#remote_address
    def test_local_and_remote_address
      alice_local_addr = nil
      alice_remote_addr = nil
      alice = ScripTTY::Net::EventLoop.new
      alice_addr = alice.on_accept(['localhost', 0]) { |conn|
        alice_local_addr = conn.local_address
        alice_remote_addr = conn.remote_address
        conn.on_close { conn.master.exit }
        conn.close
      }
      bob_local_addr = nil
      bob_remote_addr = nil
      bob = ScripTTY::Net::EventLoop.new
      bob_addr = bob.on_connect(alice_addr) { |conn|
        bob_local_addr = conn.local_address
        bob_remote_addr = conn.remote_address
        conn.on_close { conn.master.exit }
        conn.close
      }

      # Execute
      thread_status = run_threads(:alice => alice, :bob => bob)

      assert_equal alice_addr, alice_local_addr
      assert_equal alice_addr, bob_remote_addr
      assert_equal alice_remote_addr, bob_local_addr
      assert_thread_status(thread_status)
    end

    def test_accept_multiple
      # Listen on two different ports (chosen by the operating system)
      alice_accepted = []
      alice = ScripTTY::Net::EventLoop.new
      alice_addrs = alice.on_accept([['localhost', 0], ['localhost', 0]], :multiple => true) { |conn|
        alice_accepted << conn.local_address
        conn.on_close { conn.master.exit if alice_accepted.length == 2 }
        conn.close
      }

      bob_connected = nil
      bob = ScripTTY::Net::EventLoop.new
      bob_addr = bob.on_connect(alice_addrs[0]) { |conn|
        bob_connected = conn.remote_address
        conn.close
      }

      carol_connected = nil
      carol = ScripTTY::Net::EventLoop.new
      carol_addr = carol.on_connect(alice_addrs[1]) { |conn|
        carol_connected = conn.remote_address
        conn.close
      }

      # Execute
      thread_status = run_threads(:alice => alice, :bob => bob, :carol => carol)

      assert_equal alice_addrs.sort, alice_accepted.sort, "alice should accepted a connection on both ports"
      assert_equal alice_addrs[0], bob_connected, "bob should connect to alice's first port"
      assert_equal alice_addrs[1], carol_connected, "carol should connect to alice's second port"
      assert_thread_status(thread_status)
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

    private

      def run_threads(event_loops, timeout=5)
        thread_status = nil
        threads = {}
        begin
          event_loops.each_pair { |name, event_loop| threads[name] = Thread.new { event_loop.main } }
          t0 = Time.now
          until Time.now - t0 >= timeout
            break if threads.values.inject(true) { |r, t| r && !t.alive? }    # break if all threads are dead
            sleep(0.5)
          end
          thread_status = {}
          threads.each_pair { |name, t|
            thread_status[name] = t.alive?
          }
        ensure
          event_loops.values.each { |event_loop| event_loop.exit }
          threads.values.each { |t| t.join }
        end
        thread_status
      end

      def assert_thread_status(thread_status)
        expected = {}
        thread_status.keys.each do |name|
          expected[name] = false
        end
        assert_equal(expected, thread_status, "threads did not exit in specified time")
      end
  end   # defined?(Java)
end # class
