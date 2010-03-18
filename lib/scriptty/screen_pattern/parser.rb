# = Low-level (syntax-only) parser for screen pattern files
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

require 'multibyte'
require 'iconv'
require 'strscan'

module ScripTTY
  module ScreenPattern
    # Low-level (syntax only) parser for screen pattern files
    #
    # Parses a file containing screen patterns, yielding hashes.
    class Parser
      # NOTE: Ruby Regexp matching depends on the value of $KCODE, which gets
      # changed by the 'multibyte' library (and Rails) from the default of "NONE" to "UTF8".
      # The regexps here are designed to work exclusively with individual BYTES
      # in UTF-8 strings, so we need to use the //n flag in all regexps here so
      # that $KCODE is ignored.
      # NOTE: The //n flag is not preserved by Regexp#to_s; you need the //n
      # flag on the regexp object that is actually being matched.

      COMMENT = /\s*#.*$/no
      OPTIONAL_COMMENT = /#{COMMENT}|\s*$/no
      IDENTIFIER = /[a-zA-Z0-9_]+/n
      RECTANGLE = /\(\s*\d+\s*,\s*\d+\s*\)\s*-\s*\(\s*\d+\s*,\s*\d+\s*\)/n
      TUPLE = /\(\s*\d+(?:\s*,\s*\d+)*\s*\)/n
      STR_UNESCAPED = /[^"\\\t\r\n]/n
      STR_OCTAL = /\\[0-7]{3}/n
      STR_HEX = /\\x[0-9A-Fa-f]{2}/n
      STR_SINGLE = /\\[enrt\\]|\\[^a-zA-Z0-9]/n
      STRING = /"(?:#{STR_UNESCAPED}|#{STR_OCTAL}|#{STR_HEX}|#{STR_SINGLE})*"/no
      HEREDOCSTART = /<<#{IDENTIFIER}/no
      SCREENNAME_LINE = /^\[(#{IDENTIFIER})\]\s*$/no
      BLANK_LINE = /^\s*$/no
      COMMENT_LINE = /^#{OPTIONAL_COMMENT}$/no

      class <<self
        def parse(s, &block)
          new(s, &block).parse
          nil
        end
        protected :new    # Users should not instantiate this object directly
      end

      def initialize(s, &block)
        raise ArgumentError.new("no block given") unless block
        @block = block
        @lines = preprocess(s).split("\n").map{|line| "#{line}\n"}
        @line = nil
        @lineno = 0
        @state = :start
      end

      def parse
        until @lines.empty?
          @line = @lines.shift
          @lineno += 1
          send("handle_#{@state}_state")
        end
        handle_eof
      end

      private

        # Top level of the configuration file
        def handle_start_state
          return if @line =~ BLANK_LINE
          return if @line =~ COMMENT_LINE
          @screen_name = nil

          if @line =~ SCREENNAME_LINE   # start of screen "[screen_name]"
            @screen_name = $1
            @screen_properties = {}
            @state = :screen
            return
          end

          parse_fail("expected [identifier]")
        end

        def handle_screen_state
          return if @line =~ BLANK_LINE
          return if @line =~ COMMENT_LINE
          if @line =~ SCREENNAME_LINE
            handle_done_screen
            return handle_start_state
          end
          if @line =~ /^(#{IDENTIFIER})\s*:\s*(?:(#{STRING})|(#{RECTANGLE})|(#{HEREDOCSTART}|(#{TUPLE})))#{OPTIONAL_COMMENT}$/no
            k, v_str, v_rect, v_heredoc, v_tuple = [$1, parse_string($2), parse_rectangle($3), parse_heredocstart($4), parse_tuple($5)]
            if v_str
              set_screen_property(k, v_str)
            elsif v_rect
              set_screen_property(k, v_rect)
            elsif v_tuple
              set_screen_property(k, v_tuple)
            elsif v_heredoc
              @heredoc = {
                :propname => k,
                :delimiter => v_heredoc,
                :content => "",
              }
              @state = :heredoc
            else
              raise "BUG"
            end
          else
            parse_fail("expected: key:value or [identifier]")
          end
        end

        def handle_eof
          if @state == :start
            # Do nothing
          elsif @state == :screen
            handle_done_screen
          elsif @state == :heredoc
            parse_fail("expected: #{@heredoc[:delimiter].inspect}, got EOF")
          else
            raise "BUG: unhandled EOF on state #{@state}"
          end
        end

        def handle_heredoc_state
          if @line =~ /^#{Regexp.escape(@heredoc[:delimiter])}\s*$/n
            # End of here-document
            set_screen_property(@heredoc[:propname], @heredoc[:content])
            @heredoc = nil
            @state = :screen
          else
            @heredoc[:content] << @line
          end
        end

        def handle_done_screen
          @block.call({ :name => @screen_name, :properties => @screen_properties })
          @screen_name = @screen_properties = nil
          @state = :start
        end

        def set_screen_property(k,v)
          @screen_properties[k] = v
        end

        def parse_string(str)
          return nil unless str
          retval = []
          s = StringScanner.new(str)
          unless s.scan /"/n
            parse_fail("unable to parse string #{str.inspect}")
          end
          until s.eos?
            if (m = s.scan STR_UNESCAPED)
              retval << m
            elsif (m = s.scan STR_OCTAL)
              retval << [m[1..-1].to_i(8)].pack("C*")
            elsif (m = s.scan STR_HEX)
              retval << [m[2..-1].to_i(16)].pack("C*")
            elsif (m = s.scan STR_SINGLE)
              c = m[1..-1]
              retval << case c
                when 'e'
                  "\e"
                when 'n'
                  "\n"
                when 'r'
                  "\r"
                when 't'
                  "\t"
                when /[^a-zA-Z]/n
                  c
                else
                  raise "BUG"
                end
            elsif (m = s.scan /"/) # End of string
              parse_fail("unable to parse string #{str.inspect}") unless s.eos?
            else
              parse_fail("unable to parse string #{str.inspect}")
            end
          end
          retval.join
        end

        # Parse (row1,col1)-(row2,col2) into [row1, col1, row2, col2]
        def parse_rectangle(str)
          return nil unless str
          str.split(/[(,)\-\s]+/n, -1)[1..-2].map{|n| n.to_i}
        end

        # Parse (a, b, ...) into [a, b, ...]
        def parse_tuple(str)
          parse_rectangle(str)
        end

        def parse_heredocstart(str)
          return nil unless str
          str[2..-1]
        end

        def parse_fail(message=nil)
          raise ArgumentError.new("error:line #{@lineno}: #{message || 'parse error'}")
        end

        # Pre-process an input string.
        #
        # This converts the string into UTF-8, and replaces platform-specific newlines with "\n"
        def preprocess(s, source_encoding=nil)
          unless source_encoding
            # Text files on Windows can be saved in a few different "Unicode"
            # encodings.  Decode the common ones into UTF-8.
            source_encoding =
              if s =~ /\A\xef\xbb\xbf/    # UTF-8+BOM
                "UTF-8"
              elsif s =~ /\A(\xfe\xff|\xff\xfe)/   # UTF-16 BOM (big or little endian)
                "UTF-16"
              else
                "UTF-8"   # assume UTF-8
              end
          end
          # XXX TODO FIXME: There's a bug in JRuby's Iconv that prevents
          # Iconv::IllegalSequence from being raised.  Instead, the source string
          # is returned.  We should handle this somehow.
          (s,) = Iconv.iconv("UTF-8", source_encoding, s)
          s = s.gsub(/\xef\xbb\xbf/, "")    # Strip the UTF-8 BYTE ORDER MARK (U+FEFF)
          s = s.gsub(/\r\n/, "\n").gsub(/\r/, "\n")   # Replace CR and CRLF with LF (Unix newline)
          s = Multibyte::Chars.new(s).normalize(:c).to_a.join # Unicode Normalization Form C
        end
    end
  end
end
