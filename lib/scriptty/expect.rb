# = Expect object
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

require 'scriptty/exception'
require 'scriptty/net/event_loop'
require 'scriptty/term'
require 'scriptty/screen_pattern'
require 'scriptty/util/transcript/writer'
require 'set'
require 'pp'

module ScripTTY
  class Expect

    # Methods to export to Evaluator
    EXPORTED_METHODS = Set.new [:init_term, :term, :connect, :screen, :expect, :on, :wait, :send, :send_password, :capture, :match, :push_patterns, :pop_patterns, :exit, :eval_script_file, :eval_script_inline, :sleep, :set_timeout, :load_screens, :print, :puts, :p, :pp ]

    attr_reader :term   # The terminal emulation object

    attr_reader :capture  # The last non-background captured fields.  For a ScreenPattern match, this is a Hash of fields.  For a String or Regexp match, this is a MatchData object.
    alias match capture   # "match" is the deprecated name for "capture"

    attr_accessor :transcript_writer # Set this to an instance of ScripTTY::Util::Transcript::Writer

    # Initialize the Expect object.
    def initialize(options={})
      @net = ScripTTY::Net::EventLoop.new
      @receive_buffer = []    # Bytes received that have not been processed yet
      @suspended = false
      @effective_patterns = nil
      @term_name = nil
      @effective_patterns = []    # Array of PatternHandle objects
      @pattern_stack = []
      @wait_result = nil   # (non-background) PatternHandle that will cause the next wait() method to return
      @evaluator = Evaluator.new(self)
      @match_buffer = ""
      @timeout = nil
      @timeout_timer = nil
      @transcript_writer = options[:transcript_writer]
      @screen_patterns = {}
    end

    # Get instance variable from the Evaluator
    def [](varname)
      @evaluator.instance_variable_get("@#{varname}")
    end

    # Set an instance variable on the Evaluator
    def []=(varname, value)
      @evaluator.instance_variable_set("@#{varname}", value)
    end

    def set_timeout(seconds)
      fail_unexpected_block if block_given?
      raise ArgumentError.new("argument to set_timeout must be Numeric or nil") unless seconds.is_a?(Numeric) or seconds.nil?
      if seconds
        @timeout = seconds.to_f
      else
        @timeout = nil
      end
      refresh_timeout
      nil
    end

    # Load and evaluate a script from a file.
    def eval_script_file(path)
      fail_unexpected_block if block_given?
      eval_script_inline(File.read(path), path)
    end

    # Evaluate a script specified as a string.
    def eval_script_inline(str, filename=nil, lineno=nil)
      fail_unexpected_block if block_given?
      @evaluator.instance_eval(str, filename || "(inline)", lineno || 1)
    end

    # Initialize a terminal emulator.
    #
    # If a name is specified, use that terminal type.  Otherwise, use the
    # previous terminal type.
    def init_term(name=nil)
      @transcript_writer.info("Script executing command", "init_term", name || "") if @transcript_writer
      name ||= @term_name
      @term_name = name
      raise ArgumentError.new("No previous terminal specified") unless name
      without_timeout {
        @term = ScripTTY::Term.new(name)
        @term.on_unknown_sequence do |seq|
          @transcript_writer.info("Unknown escape sequence", seq) if @transcript_writer
        end
      }
      nil
    end

    # Connect to the specified address.  Return true if the connection was
    # successful.  Otherwise, raise an exception.
    def connect(remote_address)
      @transcript_writer.info("Script executing command", "connect", *remote_address.map{|a| a.inspect}) if @transcript_writer
      connected = false
      connect_error = nil
      @conn = @net.connect(remote_address) do |c|
        c.on_connect { connected = true; handle_connect; @net.suspend }
        c.on_connect_error { |e| connect_error = e; @net.suspend }
        c.on_receive_bytes { |bytes| handle_receive_bytes(bytes) }
        c.on_close { @conn = nil; handle_connection_close }
      end
      dispatch until connected or connect_error or @net.done?
      if connect_error
        transcribe_connect_error(connect_error)
        raise ScripTTY::Exception::ConnectError.new(connect_error)
      end
      refresh_timeout
      connected
    end

    # Add the specified pattern to the effective pattern list.
    #
    # Return the PatternHandle for the pattern.
    #
    # Options:
    # [:continue]
    #   If true, matching this pattern will not cause the wait method to
    #   return.
    def on(pattern, opts={}, &block)
      case pattern
      when String
        @transcript_writer.info("Script executing command", "on", "String", pattern.inspect) if @transcript_writer
        ph = PatternHandle.new(/#{Regexp.escape(pattern)}/n, block, opts[:background])
      when Regexp
        @transcript_writer.info("Script executing command", "on", "Regexp", pattern.inspect) if @transcript_writer
        if pattern.kcode == "none"
          ph = PatternHandle.new(pattern, block, opts[:background])
        else
          ph = PatternHandle.new(/#{pattern}/n, block, opts[:background])
        end
      when ScreenPattern
        @transcript_writer.info("Script executing command", "on", "ScreenPattern", pattern.name, opts[:background] ? "BACKGROUND" : "") if @transcript_writer
        ph = PatternHandle.new(pattern, block, opts[:background])
      else
        raise TypeError.new("Unsupported pattern type: #{pattern.class.inspect}")
      end
      @effective_patterns << ph
      ph
    end

    # Sleep for the specified number of seconds
    def sleep(seconds)
      @transcript_writer.info("Script executing command", "sleep", seconds.inspect) if @transcript_writer
      sleep_done = false
      @net.timer(seconds) { sleep_done = true ; @net.suspend }
      dispatch until sleep_done
      refresh_timeout
      nil
    end

    # Return the named ScreenPattern (or nil if no such pattern exists)
    def screen(name)
      fail_unexpected_block if block_given?
      @screen_patterns[name.to_sym]
    end

    # Load screens from the specified filenames
    def load_screens(filenames_or_glob)
      fail_unexpected_block if block_given?
      if filenames_or_glob.is_a?(String)
        filenames = Dir.glob(filenames_or_glob)
      elsif filenames_or_glob.is_a?(Array)
        filenames = filenames_or_glob
      else
        raise ArgumentError.new("load_screens takes a string(glob) or an array, not #{filenames.class.name}")
      end
      filenames.each do |filename|
        ScreenPattern.parse(File.read(filename)).each do |pattern|
          @screen_patterns[pattern.name.to_sym] = pattern
        end
      end
      nil
    end

    # Convenience function.
    #
    # == Examples
    #  # Wait for a single pattern to match.
    #  expect("login: ")
    #
    #  # Wait for one of several patterns to match.
    #  expect {
    #    on("login successful") { ... }
    #    on("login incorrect") { ... }
    #  }
    def expect(pattern=nil)
      raise ArgumentError.new("no pattern and no block given") if !pattern and !block_given?
      @transcript_writer.info("Script expect block BEGIN") if @transcript_writer and block_given?
      push_patterns
      begin
        on(pattern) if pattern
        yield if block_given?
        wait
      ensure
        pop_patterns
        @transcript_writer.info("Script expect block END") if @transcript_writer and block_given?
      end
    end

    # Push a copy of the effective pattern list to an internal stack.
    def push_patterns
      fail_unexpected_block if block_given?
      @pattern_stack << @effective_patterns.dup
    end

    # Pop the effective pattern list from the stack.
    def pop_patterns
      fail_unexpected_block if block_given?
      raise ArgumentError.new("pattern stack empty") if @pattern_stack.empty?
      @effective_patterns = @pattern_stack.pop
    end

    # Wait for an effective pattern to match.
    #
    # Clears the character-match buffer on return.
    def wait
      fail_unexpected_block if block_given?
      @transcript_writer.info("Script executing command", "wait") if @transcript_writer
      process_receive_buffer unless @wait_result
      dispatch until @wait_result
      refresh_timeout
      @wait_result = nil
      nil
    end

    # Send bytes to the remote application.
    #
    # NOTE: This method returns immediately, even if not all the bytes are
    # finished being sent.  Remaining bytes will be sent during an expect,
    # wait, or sleep call.
    def send(bytes)
      fail_unexpected_block if block_given?
      @transcript_writer.from_client(bytes) if @transcript_writer
      @conn.write(bytes)
      true
    end

    # Send password to the remote application.
    #
    # This works like the send method, but "**PASSWORD**" is shown in the
    # transcript instead of the actual bytes sent.
    def send_password(bytes)
      fail_unexpected_block if block_given?
      @transcript_writer.from_client("**PASSWORD**") if @transcript_writer
      @conn.write(bytes)
      true
    end

    # Close the connection and exit.
    def exit
      fail_unexpected_block if block_given?
      @transcript_writer.info("Script executing command", "exit") if @transcript_writer
      @net.exit
      dispatch until @net.done?
      @transcript_writer.close if @transcript_writer
    end

    # Generate a ScreenPattern from the current terminal state, and optionally
    # append it to the specified file.
    #
    # NOTE: This method is intended for script development only; it is not
    # exported to the Evaluator.
    def dump(filename=nil)
      fail_unexpected_block if block_given?
      result = ScreenPattern.from_term(@term).generate
      if filename
        File.open(filename, "a") { |outfile|
          outfile.puts(result); outfile.puts("")
        }
        nil
      else
        result
      end
    end

    # Like regular Ruby "puts", but also logs to the transcript.
    def puts(*args)
      @transcript_writer.info("puts", *args.map{|a| a.to_s}) if @transcript_writer
      Kernel.puts(*args)
    end

    # Like regular Ruby "print", but also logs to the transcript.
    def print(*args)
      @transcript_writer.info("print", *args.map{|a| a.to_s}) if @transcript_writer
      Kernel.print(*args)
    end

    # Like regular Ruby "p", but also logs to the transcript.
    def p(*args)
      @transcript_writer.info("p", *args.map{|a| a.to_s}) if @transcript_writer
      Kernel.p(*args)
    end

    # Like regular Ruby "pp", but also logs to the transcript.
    def pp(*args)
      @transcript_writer.info("pp", *args.map{|a| a.to_s}) if @transcript_writer
      PP.pp(*args)
    end

    private

      def fail_unexpected_block
        caller[0] =~ /`(.*?)'/
        method_name = $1
        raise ArgumentError.new("`#{method_name}' method given but does not take a block")
      end

      # Kick the watchdog timer
      def refresh_timeout
        disable_timeout
        enable_timeout
      end

      def without_timeout
        raise ArgumentError.new("no block given") unless block_given?
        disable_timeout
        begin
          yield
        ensure
          enable_timeout
        end
      end

      # Disable timeout handling
      def disable_timeout
        if @timeout_timer
          @timeout_timer.cancel
          @timeout_timer = nil
        end
        nil
      end

      # Enable timeout handling (if @timeout is set)
      def enable_timeout
        if @timeout
          @timeout_timer = @net.timer(@timeout, :daemon=>true) {
            raise ScripTTY::Exception::Timeout.new("Timed out waiting for #{@effective_patterns.map{|pattern_handle| pattern_handle.pattern}.inspect}")
          }
        end
        nil
      end

      # Re-enter the dispatch loop
      def dispatch
        if @suspended
          @suspended = @net.resume
        else
          @suspended = @net.main
        end
      end

      def handle_connection_close   # XXX - we should raise an error when disconnected prematurely
        @transcript_writer.server_close("connection closed") if @transcript_writer
        self.exit
      end

      def handle_connect
        @transcript_writer.server_open(*@conn.remote_address) if @transcript_writer
        init_term
      end

      def transcribe_connect_error(e)
        if @transcript_writer
          @transcript_writer.exception(e)
        end
      end

      def handle_receive_bytes(bytes)
        @transcript_writer.from_server(bytes) if @transcript_writer
        @receive_buffer += bytes.split(//n)
        process_receive_buffer
      end

      def process_receive_buffer
        if @receive_buffer.empty?
          check_expect_match
        else
          pos = 0
          while (byte = @receive_buffer.shift)
            @match_buffer << byte
            @term.feed_byte(byte)
            check_expect_match
            break if @wait_result
          end
        end
        nil
      end

      # Check for a match.
      #
      # If there is a (non-background) match, set @wait_finished and return true.  Otherwise, return false.
      def check_expect_match
        found = true
        while found
          found = false
          @effective_patterns.each { |ph|
            case ph.pattern
            when Regexp
              m = ph.pattern.match(@match_buffer)
              @match_buffer = @match_buffer[m.end(0)..-1] if m    # truncate match buffer
            when ScreenPattern
              m = ph.pattern.match_term(@term)
              @match_buffer = "" if m   # truncate match buffer if a screen matches
            else
              raise "BUG: pattern is #{ph.pattern.inspect}"
            end

            next unless m   # Only continue if the current pattern matched

            if ph.background?
              puts "BACKGROUND MATCH"     # DEBUG FIXME
              # Patterns configured with :background=>true never cause wait()
              # to return.  They are "background" patterns.
              ph.callback.call(m) if ph.callback
              found = true
            elsif !@wait_result   # only match non-background patterns if no @wait_result is set
              puts "FOREGROUND MATCH: #{ph.inspect}"     # DEBUG FIXME
              puts "MB: #{@match_buffer.inspect}" # DEBUG FIXME
              puts "RB: #{@receive_buffer.inspect}" # DEBUG FIXME
              # Patterns configured without :background=>true cause wait()
              # to return.  They are "foreground" patterns.
              @capture = m
              @wait_result = ph   # make the next (or current) wait() call return
              ph.callback.call(m) if ph.callback
              @net.suspend
              return true
            end
          }
        end
        false
      end

    class Evaluator
      def initialize(expect_object)
        @_expect_object = expect_object
      end

      # Define proxy methods
      EXPORTED_METHODS.each do |m|
        # We would use define_method, but JRuby 1.4 doesn't support defining
        # a block that takes a block. http://jira.codehaus.org/browse/JRUBY-4180
        class_eval("def #{m}(*args, &block) @_expect_object.__send__(#{m.inspect}, *args, &block); end")
      end
    end

    class PatternHandle
      attr_reader :pattern
      attr_reader :callback

      def initialize(pattern, callback, background)
        @pattern = pattern
        @callback = callback
        @background = background
      end

      def background?
        @background
      end
    end

    class Match
      attr_reader :pattern_handle
      attr_reader :result

      def initialize(pattern_handle, result)
        @pattern_handle = pattern_handle
        @result = result
      end
    end

  end
end
