# = Tests for ScripTTY::Util::Transcript::Writer
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
require 'scriptty/util/transcript/writer'
require 'stringio'

class TranscriptWriterTest < Test::Unit::TestCase
  def test_methods
    sio = StringIO.new
    writer = ScripTTY::Util::Transcript::Writer.new(sio)
    writer.override_timestamp = 88.0
    writer.client_open("10.0.0.5", 55555)
    writer.server_open("10.0.0.1", 54321)
    writer.from_client("\e[33m")
    writer.from_server("\e[33m")
    writer.client_parsed("t_foo", "\e[33m")
    writer.server_parsed("t_foo", "\e[33m")
    writer.client_close("msg")
    writer.server_close("msg")
    writer.info("msg")
    writer.exception_head("ArgumentError", "msg")
    writer.exception_backtrace("line1")
    writer.exception_backtrace("line2")
    writer.close
    expected = <<-'EOF'.strip.split("\n").map{|line| line.strip}.join("\n") + "\n"
      [88.000] Copen "10.0.0.5" "55555"
      [88.000] Sopen "10.0.0.1" "54321"
      [88.000] C "\033[33m"
      [88.000] S "\033[33m"
      [88.000] Cp "t_foo" "\033[33m"
      [88.000] Sp "t_foo" "\033[33m"
      [88.000] Cx "msg"
      [88.000] Sx "msg"
      [88.000] * "msg"
      [88.000] EXC "ArgumentError" "msg"
      [88.000] EX+ "line1"
      [88.000] EX+ "line2"
    EOF
    assert_equal expected, sio.string
  end

  def test_string_encoding
    sio = StringIO.new
    writer = ScripTTY::Util::Transcript::Writer.new(sio)
    writer.override_timestamp = 99.0
    writer.from_client((0..255).to_a.pack("C*"))
    writer.close

    # Backslash, double-quotes, and non-printableASCII (characters outside the
    # range \x20-\x7e) should be octal-encoded.
    expected = '[99.000] C "\000\001\002\003\004\005\006\007'
    expected += '\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027'
    expected += '\030\031\032\033\034\035\036\037 !\042#$%&' + "'"
    expected += '()*+,-./0123456789:;<=>?'
    expected += '@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\134]^_'
    expected += '`abcdefghijklmnopqrstuvwxyz{|}~\177'
    expected += '\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217'
    expected += '\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237'
    expected += '\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257'
    expected += '\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277'
    expected += '\300\301\302\303\304\305\306\307\310\311\312\313\314\315\316\317'
    expected += '\320\321\322\323\324\325\326\327\330\331\332\333\334\335\336\337'
    expected += '\340\341\342\343\344\345\346\347\350\351\352\353\354\355\356\357'
    expected += '\360\361\362\363\364\365\366\367\370\371\372\373\374\375\376\377'
    expected += "\"\n"
    assert_equal expected, sio.string
  end

  # Check that the timestamp of the first message is zero, or within the amount
  # of time it took to instantiate the writer and emit the first line.
  def test_initial_timestamp
    sio = StringIO.new
    t0 = Time.now
    writer = ScripTTY::Util::Transcript::Writer.new(sio)
    writer.info("foo")
    t1 = Time.now
    assert sio.string =~ /^\[([\d.]+)\]/
    relative_timestamp = $1
    assert !relative_timestamp.empty?
    relative_timestamp = relative_timestamp.to_f  # convert to float
    assert (relative_timestamp >= 0.0 && relative_timestamp <= (t1 - t0))
  end

  # Check that timestamps increase
  def test_timestamps_increase
    sio = StringIO.new
    writer = ScripTTY::Util::Transcript::Writer.new(sio)
    last_timestamp = 0.0
    200.times do
      sleep 0.002    # make sure the time increases enough to be within the resolution of the timestamp
      writer.info("foo")
      assert sio.string.strip.split("\n").last =~ /^\[([\d.]+)\]/
      current_timestamp = $1.to_f
      assert current_timestamp > last_timestamp, "timestamps should increase"
      last_timestamp = current_timestamp
    end
  end

  # Test the override_timestamp attribute
  def test_override_timestamp
    sio = StringIO.new
    writer = ScripTTY::Util::Transcript::Writer.new(sio)
    writer.override_timestamp = 1.0 ; writer.info("one") ; sleep 0.02; writer.info("two")
    writer.override_timestamp = 3.101 ; writer.info("three")
    writer.override_timestamp = 4.222 ; writer.info("four")
    writer.override_timestamp = 5.001 ; writer.info("five")
    writer.close
    expected = <<-'EOF'.strip.split("\n").map{|line| line.strip}.join("\n") + "\n"
      [1.000] * "one"
      [1.000] * "two"
      [3.101] * "three"
      [4.222] * "four"
      [5.001] * "five"
    EOF
    assert_equal expected, sio.string
  end

  # Test the exception_head and exception_backtrace messages
  def test_exception
    sio = StringIO.new
    writer = ScripTTY::Util::Transcript::Writer.new(sio)
    writer.override_timestamp = 0.0
    begin
      raise ArgumentError.new("foo")
    rescue => e
      writer.exception(e)
    end
    writer.close

    # Parse the transcript
    sio = StringIO.new(sio.string)
    reader = ScripTTY::Util::Transcript::Reader.new(sio)
    entries = []
    while (entry = reader.next_entry)
      entries << entry
    end
    assert_equal [0.0, :exception_head, ["ArgumentError", "foo"]], entries.shift
    assert_match /^\[0\.0, :exception_backtrace, \["[^"]*:in `test_exception'"\]\]$/, entries.shift.inspect
    until entries.empty?
      assert_equal :exception_backtrace, entries.shift[1]
    end
  end
end
