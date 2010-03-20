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
    # Parser for screen pattern files
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
      NIL = /nil/n
      RECTANGLE = /\(\s*\d+\s*,\s*\d+\s*\)\s*-\s*\(\s*\d+\s*,\s*\d+\s*\)/n
      STR_UNESCAPED = /[^"\\\t\r\n]/n
      STR_OCTAL = /\\[0-7]{3}/n
      STR_HEX = /\\x[0-9A-Fa-f]{2}/n
      STR_SINGLE = /\\[enrt\\]|\\[^a-zA-Z0-9]/n
      STRING = /"(?:#{STR_UNESCAPED}|#{STR_OCTAL}|#{STR_HEX}|#{STR_SINGLE})*"/no
      INTEGER = /-?\d+/no
      TWO_INTEGER_TUPLE = /\(\s*#{INTEGER}\s*,\s*#{INTEGER}\s*\)/no
      TUPLE_ELEMENT = /#{INTEGER}|#{STRING}|#{NIL}|#{TWO_INTEGER_TUPLE}/no # XXX HACK: We actually want nested tuples, but we can't use regexp matching for that
      TUPLE = /\(\s*#{TUPLE_ELEMENT}(?:\s*,\s*#{TUPLE_ELEMENT})*\s*\)/no
      HEREDOCSTART = /<<#{IDENTIFIER}/no
      SCREENNAME_LINE = /^\[(#{IDENTIFIER})\]\s*$/no
      BLANK_LINE = /^\s*$/no
      COMMENT_LINE = /^#{OPTIONAL_COMMENT}$/no

      SINGLE_CHAR_PROPERTIES = %w( char_cursor char_ignore char_field )
      TWO_TUPLE_PROPERTIES = %w( position size cursor_pos )
      RECOGNIZED_PROPERTIES = SINGLE_CHAR_PROPERTIES + TWO_TUPLE_PROPERTIES + %w( rectangle fields text )

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
                :lineno => @lineno,
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
          # Remove stuff that's irrelevant once the screen is parsed
          @screen_properties.delete("char_field")
          @screen_properties.delete("char_cursor")
          @screen_properties.delete("char_ignore")

          # Invoke the passed-in block with the parsed screen information
          @block.call({ :name => @screen_name, :properties => @screen_properties })

          # Reset to the initial state
          @screen_name = @screen_properties = nil
          @state = :start
        end

        def validate_single_char_property(k, v)
          c = v.chars.to_a    # Split field into array of single-character (but possibly multi-byte) strings
          unless c.length == 1
            parse_fail("#{k} must be a single character or Unicode code point", property_lineno)
          end
        end

        def validate_tuple_property(k, v, length=2)
          parse_fail("#{k} must be a #{length}-tuple", property_lineno) unless v.length == length
          parse_fail("#{k} must contain positive integers", property_lineno) unless v[0] >=0 and v[1] >= 0
        end

        def set_screen_text(k, v, lineno=nil)
          lineno ||= property_lineno

          text = v.split("\n").map{|line| line.rstrip}   # Split on newlines and strip trailing whitespace

          # Get the implicit size of the screen from the text
          parse_fail("#{k} must be surrounded by identical +-----+ lines", lineno) unless text[0] =~ /^\+(-+)\+$/
          width = $1.length
          height = text.length-2
          parse_fail("#{k} must be surrounded by identical +-----+ lines", lineno + text.length) unless text[-1] == text[0]    # TODO - test if this is the correct offset
          text = text[1..-2]    # strip top and bottom +------+ lines
          lineno += 1   # Increment line number to compensate

          # If there is an explicitly-specified size of the screen, compare against it.
          # If there is no explicitly-specified size of the screen, use the implicit size.
          explicit_height, explicit_width = @screen_properties['size']
          explicit_height ||= height ; explicit_width ||= width    # Default to the implicit size
          if (explicit_height != height) or (explicit_width != width)
            parse_fail("#{k} dimensions (#{height}x#{width}) conflict with explicit size (#{explicit_height}x#{explicit_width})", lineno)
          else
            set_screen_property("size", [height, width])    # in case it wasn't set explicitly
          end

          match_list = set_properties_from_grid(text,
            :property_name => k,
            :start_lineno => lineno+1,
            :width => width,
            :char_cursor => @screen_properties['char_cursor'],
            :char_field => @screen_properties['char_field'],
            :char_ignore => @screen_properties['char_ignore'])

          if match_list and !match_list.empty?
            @screen_properties['matches'] = match_list    # XXX TODO - This will probably need to change
          end
        end

        # If no position has been specified for this pattern, default to the top-left corner of the window.
        def ensure_position
          set_screen_property('position', [0,0]) unless @screen_properties['position']
        end

        # Convert a relative [row,column] or [row, col1..col2] into an absolute position or range.
        def abs_pos(relative_pos)
          screen_pos = @screen_properties['position']
          if relative_pos[1].is_a?(Range)
            [relative_pos[0]+screen_pos[0], relative_pos[1].first+screen_pos[1]..relative_pos[1].last+screen_pos[1]]
          else
            [relative_pos[0]+screen_pos[0], relative_pos[1]+screen_pos[1]]
          end
        end

        # Walk through all the characters in the pattern, building up the
        # pattern-matching data structures.
        def set_properties_from_grid(lines, options={})
          # Get options
          height = lines.length
          k = options[:property_name]
          width = options[:width]
          start_lineno = options[:start_lineno] || 1
          char_cursor = options[:char_cursor]
          char_field = options[:char_field]
          char_ignore = options[:char_ignore]

          # Convert each row into an array of single-character (possibly multi-byte) strings
          lines_chars = lines.map{|line| line.chars.to_a}

          # Each row consists of a grid bordered by vertical bars,
          # followed by field names, e.g.:
          #   |.......| ("foo", "bar")
          # Separate the grid from the field names
          grid = []
          row_field_names = []
          (0..height-1).each do |row|
            start_border = lines_chars[row][0]
            end_border = lines_chars[row][width+1]
            parse_fail("column 1: expected '|', got #{start_border.inspect}", start_lineno + row) unless start_border == "|"
            parse_fail("column #{width+2}: expected '|', got #{end_border.inspect}", start_lineno + row) unless end_border == "|"
            grid << lines_chars[row][1..width]
            row_field_names << (parse_string_or_null_tuple(lines_chars[row][width+2..-1].join, start_lineno + row, width+3) || [])
          end

          match_positions = []
          field_positions = []
          cursor_pos = nil
          (0..height-1).each do |row|
            (0..width-1).each do |column|
              pos = [row, column]
              c = grid[row][column]
              if c.nil? or c == char_ignore
                # do nothing; ignore this character cell
              elsif c == char_field
                field_positions << pos
              elsif c == char_cursor
                parse_fail("column #{column+2}: multiple cursors", start_lineno + row) if cursor_pos
                cursor_pos = pos
              else
                match_positions << pos
              end
            end
          end
          match_ranges_by_row = consolidate_positions(match_positions)
          field_ranges_by_row = consolidate_positions(field_positions)

          # Set the cursor position
          set_screen_property('cursor_pos', cursor_pos, start_lineno + cursor_pos[0]) if cursor_pos

          # Add fields to the screen.  Complain if there's a mismatch between
          # the number of fields found and the number identified.
          (0..height-1).each do |row|
            col_ranges = field_ranges_by_row[row] || []
            unless row_field_names[row].length == col_ranges.length
              parse_fail("field count mismatch: #{col_ranges.length} fields found, #{row_field_names[row].length} fields named or ignored", start_lineno + row)
            end
            row_field_names[row].zip(col_ranges) do |field_name, col_range|
              next unless field_name    # skip nil field names
              add_field_to_screen(field_name, abs_pos([row, col_range]), start_lineno + row)
            end
          end

          # Return the match list
          # i.e. a list of [[row, start_col], string]
          match_list = []
          match_ranges_by_row.keys.sort.each do |row|
            col_ranges = match_ranges_by_row[row]
            col_ranges.each do |col_range|
              s = grid[row][col_range].join
              # Ensure that all remaining characters are printable ASCII.  We
              # don't support Unicode matching right now.  (But we can probably
              # just remove this check when adding support later.)
              if (c = (s =~ /([^\x20-\x7e])/u))
                parse_fail("column #{c+2}: non-ASCII-printable character #{$1.inspect}", start_lineno + row)
              end
              match_list << [abs_pos([row, col_range.first]), s]
            end
          end
          match_list
        end

        # Consolidate adjacent positions and group them by row
        #
        # Example input:
        #  [[0,0], [0,1], [0,2], [1,1], [1,2], [1,4]]
        # Example output:
        #  {0: [0..2], 1: [1..2, 4..4]]
        def consolidate_positions(positions)
          results = []
          positions.each do |row, col|
            if results[-1] and results[-1][0] == row and results[-1][1].last == col-1
              results[-1][1] = results[-1][1].first..col
            else
              results << [row, col..col]
            end
          end

          # Collect ranges by row
          results_by_row = {}
          results.each do |row, col_range|
            results_by_row[row] ||= []
            results_by_row[row] << col_range
          end
          results_by_row
        end

        # Return the line number of the current property.
        #
        # This will be either @lineno, or @heredoc[:lineno] (if the latter is present)
        def property_lineno
          @heredoc ? @heredoc[:lineno] : @lineno
        end

        # Add a field to the 'fields' property.
        #
        # Raise an exception if the field already exists.
        def add_field_to_screen(name, row_and_col_range, lineno=nil)
          lineno ||= property_lineno
          row, col_range = row_and_col_range
          @screen_properties['fields'] ||= {}
          if @screen_properties['fields'].include?(name)
            parse_fail("duplicate field name #{name.inspect}", lineno)
          end
          @screen_properties['fields'][name] = [row, col_range]
          nil
        end

        def set_screen_property(k,v, lineno=nil)
          lineno ||= property_lineno
          parse_fail("Unrecognized property name #{k}", lineno) unless RECOGNIZED_PROPERTIES.include?(k)
          validate_single_char_property(k, v) if SINGLE_CHAR_PROPERTIES.include?(k)
          validate_tuple_property(k, v, 2) if TWO_TUPLE_PROPERTIES.include?(k)
          if k == "rectangle"
            set_screen_property("position", v[0,2], lineno)
            set_screen_property("size", [v[2]-v[0]+1, v[3]-v[1]+1], lineno)
          elsif k == "text"
            ensure_position   # "position", if set, must be set before this field is set
            set_screen_text(k,v, lineno)
          elsif k == "fields"
            ensure_position   # "position", if set, must be set before this field is set
            v.split("\n", -1).each_with_index do |raw_tuple, i|
              next if raw_tuple.nil? or raw_tuple.empty?
              t = parse_tuple(raw_tuple.strip, lineno+i)
              field_name, rel_pos, length = t
              unless (field_name.is_a?(String) and rel_pos.is_a?(Array) and
                      rel_pos[0].is_a?(Integer) and rel_pos[1].is_a?(Integer) and length.is_a?(Integer))
                parse_fail("incorrect field format: should be (name, (row, col), length)", lineno+i)
              end
              rel_range = [rel_pos[0], rel_pos[1]..rel_pos[1]+length]
              add_field_to_screen(field_name, abs_pos(rel_range), lineno+i)
            end
          else
            v = abs_pos(v) if k == "cursor_pos"
            # Don't allow setting a screen property more than once to different values.
            old_value = @screen_properties[k]
            unless old_value.nil? or old_value == v
              if k == "position"
                extra_note = "  NOTE: 'position' should occur before other properties in the screen definition"
              else
                extra_note = ""
              end
              parse_fail("property #{k} value #{v.inspect} conflicts with already-set value #{old_value.inspect}#{extra_note}", lineno)
            end
            @screen_properties[k] = v
          end
        end

        def parse_string(str, lineno=nil)
          return nil unless str
          retval = []
          s = StringScanner.new(str)
          unless s.scan /"/n
            parse_fail("unable to parse string #{str.inspect}", lineno)
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
              parse_fail("unable to parse string #{str.inspect}", lineno) unless s.eos?
            else
              parse_fail("unable to parse string #{str.inspect}", lineno)
            end
          end
          retval.join
        end

        # Parse (row1,col1)-(row2,col2) into [row1, col1, row2, col2]
        def parse_rectangle(str)
          return nil unless str
          str.split(/[(,)\-\s]+/n, -1)[1..-2].map{|n| n.to_i}
        end

        def parse_heredocstart(str)
          return nil unless str
          str[2..-1]
        end

        # Parse (a, b, ...) into [a, b, ...]
        def parse_tuple(str, line=nil, column=nil)
          return nil unless str
          column ||= 1
          retval = []
          s = StringScanner.new(str)

          # Leading parenthesis
          done = false
          expect_comma = false
          if s.scan /\s*\(/n
            # start of tuple
          elsif s.scan COMMENT_LINE
            # Comment or blank line
            return nil
          else
            parse_fail("column #{column+s.pos}: expected '(', got #{s.rest.chars.to_a[0].inspect}", line)
          end
          until s.eos?
            if s.scan /\)/n   # final parenthesis
              done = true
              break
            end
            next if s.scan /\s+/n    # strip whitespace
            if expect_comma
              if s.scan /,/n
                expect_comma = false
              else
                parse_fail("column #{column+s.pos}: expected ',', got #{s.rest.chars.to_a[0].inspect}", line)
              end
            else
              if (m = s.scan STRING)
                retval << parse_string(m)
              elsif (m = s.scan INTEGER)
                retval << m.to_i
              elsif (m = s.scan NIL)
                retval << nil
              elsif (m = s.scan TWO_INTEGER_TUPLE)
                retval << parse_rectangle(m)    # parse_rectangle is dumb, so it will work here
              else
                parse_fail("column #{column+s.pos}: expected STRING, got #{s.rest.chars.to_a[0].inspect}", line)
              end
              expect_comma = true
            end
          end
          parse_fail("column #{column+s.pos}: tuple truncated", line) unless done
          s.scan OPTIONAL_COMMENT
          parse_fail("column #{column+s.pos}: extra junk found: #{s.rest.inspect}", line) unless s.eos?
          retval
        end

        def parse_string_or_null_tuple(str, line=nil, column=nil)
          t = parse_tuple(str, line, column)
          return nil unless t
          t.each_with_index do |v, i|
            parse_fail("element #{i+1} of tuple is #{v.class.name}, but a string or null is required", line) unless v.nil? or v.is_a?(String)
          end
          t
        end

        def parse_fail(message=nil, line=nil)
          line ||= @lineno
          raise ArgumentError.new("error:line #{line}: #{message || 'parse error'}")
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
