# = Tests for the Capture App
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
require 'scriptty/util/transcript/reader'
require 'tempfile'

class CaptureAppTest < Test::Unit::TestCase
  LISTEN_PORT = 46457   # Randomly-chosen port; change if necessary

  if true # FIXME
    def test_dummy_disabled
      $stderr.puts "warning: CaptureAppTest disabled"  # FIXME
    end
  else  # FIXME

  def setup
    require 'scriptty/apps/capture_app'
    require 'scriptty/net/event_loop'
    raise "CaptureAppTest disabled" # FIXME
  end

  def test_basic
    app = nil
    app_thread = nil
    Tempfile.open("test") do |transcript_file|
      # Create an event loop
      evloop = ScripTTY::Net::EventLoop.new

      # Create an echo server
      echo_server = evloop.listen(['localhost', 0])
      echo_server.on_accept { |conn|
        conn.on_receive_bytes { |bytes| conn.write(bytes) }
      }
      echo_addr = "[#{echo_server.local_address[0]}]:#{echo_server.local_address[1]}"   # format as [HOST]:PORT

      # Start the capture app
      app = ScripTTY::Apps::CaptureApp.new(%W( -l localhost:#{LISTEN_PORT} -c #{echo_addr} -o #{transcript_file.path} ))
      app_thread = Thread.new { app.main }
      sleep 2   # Wait for the application to bind the socket

      # Connect to the capture app, and play "ping-pong" with the echo server
      # via the capture app: Send one byte at a time, then wait for it to come
      # back before sending the next byte.
      bytes_to_send = "Hello".split("")
      bytes_received = ""
      evloop.on_connect(['localhost', LISTEN_PORT]) { |conn|
        conn.on_close { evloop.exit }
        write_next = nil
        conn.on_receive_bytes { |bytes|
          bytes_received += bytes
          #puts "RECEIVED"
          write_next.call
        }
        write_next = Proc.new {
          unless bytes_to_send.empty?
            #puts "WRITING"
            conn.write(bytes_to_send.shift)
          else
            #puts "CLOSING"
            conn.close
          end
        }
        write_next.call
      }
      evloop.main

      sleep 2   # Wait for the application to finish
      app.exit

      # Expected transcript
      expected_transcript = [
        [:client_open, "127.0.0.1", nil],
        [:server_open, "127.0.0.1", nil],
        [:from_client, "H"],
        [:from_server, "H"],
        [:from_client, "e"],
        [:from_server, "e"],
        [:from_client, "l"],
        [:from_server, "l"],
        [:from_client, "l"],
        [:from_server, "l"],
        [:from_client, "o"],
        [:from_server, "o"],
        [:client_close, "Client connection closed"],
        [:server_close, "Server connection closed"],
      ]

      # Read transcript
      reader = ScripTTY::Util::Transcript::Reader.new
      raw_transcript = ""
      actual_transcript = []
      until transcript_file.eof?
        line = transcript_file.readline
        raw_transcript << line
        timestamp, type, args = reader.parse_line(line)
        actual_transcript << [type] + args
      end

      # Canonicalize the transcript for this test: Replace ports with nil
      actual_transcript.each {|t|
        if [:client_open, :server_open].include?(t[0])
          assert_kind_of Integer, t[2], "port should be an Integer"
          t[2] = nil
        end
      }

      assert_equal expected_transcript, actual_transcript, raw_transcript
    end
  ensure
    app.exit if app
    app_thread.join if app_thread
  end

  end # FIXME
end
