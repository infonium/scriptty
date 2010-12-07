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
require 'scriptty/util/transcript/writer'
require 'stringio'

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

    def test_basedir
      e = ScripTTY::Expect.new
      assert_equal ".", e.basedir, "basedir should default to '.'"
      e.set_basedir File.dirname(__FILE__) + "/expect"
      assert_not_equal ".", e.basedir, "basedir should be changed by set_basedir"
      e.load_screens "screens.txt"
      assert_not_nil e.screen(:hello_world), "screen should load successfully"
    end

    def test_sleep_with_and_without_transcribe
      sio = StringIO.new
      writer = ScripTTY::Util::Transcript::Writer.new(sio)

      e = ScripTTY::Expect.new
      e.transcript_writer = writer

      writer.override_timestamp = 1.0
      e.puts "Normal sleep should output transcript records"
      e.sleep(0.1)
      e.sleep(0.1)
      e.sleep(0.1)

      writer.override_timestamp = 2.0
      e.puts "sleep with :transcribe=>false should output nothing to the transcript"
      e.sleep(0.1, :transcribe=>false)
      e.sleep(0.1, :transcribe=>false)
      e.sleep(0.1, :transcribe=>false)

      writer.override_timestamp = 3.0
      e.puts "sleep with :transcribe=>true should output nothing to the transcript"
      e.sleep(0.1, :transcribe=>true)
      e.sleep(0.1, :transcribe=>true)
      e.sleep(0.1, :transcribe=>true)

      expected = <<-'EOF'.strip.split("\n").map{|line| line.strip}.join("\n") + "\n"
        [1.000] * "puts" "Normal sleep should output transcript records"
        [1.000] * "Script executing command" "sleep" "0.1"
        [1.000] * "Script executing command" "sleep" "0.1"
        [1.000] * "Script executing command" "sleep" "0.1"
        [2.000] * "puts" "sleep with :transcribe=>false should output nothing to the transcript"
        [3.000] * "puts" "sleep with :transcribe=>true should output nothing to the transcript"
        [3.000] * "Script executing command" "sleep" "0.1"
        [3.000] * "Script executing command" "sleep" "0.1"
        [3.000] * "Script executing command" "sleep" "0.1"
      EOF
      assert_equal expected, sio.string
    end
  end
end
