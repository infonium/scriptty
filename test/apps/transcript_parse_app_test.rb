# = Tests for the TranscriptParseApp
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
require 'scriptty/apps/transcript_parse_app'
require 'scriptty/util/transcript/reader'
require 'scriptty/util/transcript/writer'
require 'tempfile'

class TranscriptParseAppTest < Test::Unit::TestCase
  def test_basic
    input_events = [
        [0.0, :client_open, '127.0.0.1', 777],
        [0.1, :server_open, '127.0.0.1', 555],
        [0.2, :from_client, "Hello\r\n"],
        [1.0, :from_server, "\036~xx\001xHello\020"],
        [1.1, :from_server, "\005\007\n\020"],
        [2.0, :server_close, "Closed"],
        [2.1, :client_close, "Closed"],
    ]
    # XXX - This isn't quite right (see below) -- the
    # [:server_parsed,".","Hello"] comes out too late and with the wrong
    # timestamp.
    expected_output = [
        [0.0, :client_open, '127.0.0.1', 777],
        [0.1, :server_open, '127.0.0.1', 555],
        [0.2, :from_client, "Hello\r\n"],
        [1.0, :from_server, "\036~xx\001xHello\020"],
        [1.0, :server_parsed, "t_proprietary_escape", "\036~xx\001x"],
        #[1.0, :server_parsed, ".", "Hello"],    # XXX - ideally should be here
        [1.1, :from_server, "\005\007\n\020"],
        [1.1, :server_parsed, ".", "Hello"],    # XXX - actually is here
        [1.1, :server_parsed, "t_write_window_address", "\020\005\007"],
        [1.1, :server_parsed, "t_new_line", "\n"],
        [2.0, :server_close, "Closed"],
        [2.1, :client_close, "Closed"],
    ]

    app = nil
    Tempfile.open("testin") do |tf_input|
      Tempfile.open("testout") do |tf_output|
        tf_output.close(false)

        # Create the test transcript
        writer = ScripTTY::Util::Transcript::Writer.new(tf_input)
        input_events.each do |args|
          timestamp, type = args.shift(2)
          writer.override_timestamp = timestamp
          writer.send(type, *args)
        end
        writer.close

        ###
        # Run the app (with --keep)
        app = ScripTTY::Apps::TranscriptParseApp.new(%W( -o #{tf_output.path} --keep -t dg410 #{tf_input.path} ))
        app.main

        # Read transcript
        actual_transcript = load_transcript(tf_output.path)

        # Compare
        assert_equal_transcripts expected_output, actual_transcript

        ####
        # Run the app (without --keep)
        app = ScripTTY::Apps::TranscriptParseApp.new(%W( -o #{tf_output.path} -t dg410 #{tf_input.path} ))
        app.main

        # Read transcript
        actual_transcript = load_transcript(tf_output.path)

        # Strip :from_server from expected output
        expected_output.reject!{|e| e[1] == :from_server}

        # Compare
        assert_equal_transcripts expected_output, actual_transcript
      end
    end
  end

  private
    def load_transcript(path)
      reader = ScripTTY::Util::Transcript::Reader.new
      raw_transcript = ""
      transcript = []
      File.open(path, "r") do |transcript_file|
        until transcript_file.eof?
          line = transcript_file.readline
          raw_transcript << line
          timestamp, type, args = reader.parse_line(line)
          transcript << [timestamp, type] + args
        end
      end
      transcript
    end

    def assert_equal_transcripts(expected_transcript, actual_transcript)
      expected_transcript.zip(actual_transcript).each_with_index do |(expected, actual), i|
        assert_equal expected, actual, "line #{i+1}: should be equal"
      end
      assert_equal expected_transcript, actual_transcript, "transcripts should be equal"
    end
end
