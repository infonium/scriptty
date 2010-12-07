# = Tests for ScripTTY::RequestDispatcher
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
require 'scriptty/request_dispatcher'
require 'scriptty/util/transcript/writer'
require 'stringio'

class RequestDispatcherTest < Test::Unit::TestCase

  if !defined?(Java)
    # This test gets executed when JRuby is not detected
    def test_dummy_no_jruby
      raise LoadError.new("Cannot test ScripTTY::RequestDispatcher: Not running under JRuby")
    end

  else  # defined?(Java)

    def setup
      @r = ScripTTY::RequestDispatcher.new
    end

    def teardown
      @r.finish
    end

    def test_after_init
      after_init_ran = false
      @r.after_init { after_init_ran = true }
      @r.start
      sleep 0.2   # XXX - race condition
      assert after_init_ran, "after_init hook should run"
    end

    def test_request
      @r.start
      assert_equal :success, @r.request { init_term "dg410"; :success }
    end

    def test_standard_exception_in_request
      @r.instance_eval do
        def show_exception(*args) end   # Silence exceptions
      end

      @r.start
      assert_raise ArgumentError do
        @r.request { raise ArgumentError.new("foo") }
      end
    end

    def test_base_exception_in_request
      @r.instance_eval do
        def show_exception(*args) end   # Silence exceptions
      end

      @r.start
      assert_raise SyntaxError do
        @r.request { eval("*") }
      end
    end

    def test_idle_does_not_write_to_transcript
      sio = StringIO.new
      @r.after_init {
        self.transcript_writer = ScripTTY::Util::Transcript::Writer.new(sio)
        self.transcript_writer.override_timestamp = 88.0
      }
      @r.start
      sleep 0.5
      @r.finish
      assert_equal sio.string, %Q([88.000] * "Script executing command" "exit"\n)
    end

  end
end

