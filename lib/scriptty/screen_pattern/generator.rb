# = Generator for screen pattern files
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
require 'set'

require 'scriptty/screen_pattern/parser'

module ScripTTY
  module ScreenPattern
    class Generator
      class <<self
        # Generate a screen pattern from a specification
        #
        # Options:
        # [:force_fields]
        #   If true, the fields will be positioned in-line, even if there is
        #   matching text or cursor there.  :force_fields takes precedence over :force_cursor.
        # [:force_cursor]
        #   If true, the cursor will be positioned in-line, even if there is
        #   matching text or fields there.  :force_cursor may also be a
        #   Regexp, in which case the regexp must match in order for the field
        #   to be replaced.  :force_fields takes precedence over :force_cursor.
        # [:ignore]
        #   If specified, this is an array of [row, col0..col1] ranges.
        def generate(name, properties_and_options={})
          new(name, properties_and_options).generate
        end
        protected :new    # Users should not instantiate this object directly
      end

      IGNORE_CHAR_CHOICES = ['.', '~', "'", "^", "-", "?", " ", "░"]
      CURSOR_CHAR_CHOICES = ["@", "+", "&", "█"]
      FIELD_CHAR_CHOICES = ["#", "*", "%", "=", "_", "◆"]

      def initialize(name, properties={})
        properties = properties.dup
        @force_cursor = properties.delete(:force_cursor)
        @force_fields = properties.delete(:force_fields)
        @ignore = properties.delete(:ignore)
        load_spec(name, properties)
        make_grid
      end

      def generate
        @out = []
        @out << "[#{@name}]"
        @out << "position: #{encode_tuple(@position)}" if @position and @position != [0,0]
        @out << "size: #{encode_tuple(@size)}"
        if @char_cursor
          @out << "char_cursor: #{encode_string(@char_cursor)}"
        elsif @cursor_pos
          @out << "cursor_pos: #{encode_tuple(@cursor_pos)}"
        end
        @out << "char_ignore: #{encode_string(@char_ignore)}" if @char_ignore
        @out << "char_field: #{encode_string(@char_field)}" if @char_field
        if @explicit_fields
          @out << "fields: <<END"
          @explicit_fields.each { |f|
            @out << "  #{encode_tuple(f)}"
          }
          @out << "END"
        end
        if @text_lines
          @out << "text: <<END"
          @out += @text_lines
          @out << "END"
        end
        @out.map{|line| "#{line}\n"}.join
      end

      private

        def make_grid
          # Initialize grid as 2D array of nils
          height, width = @size
          grid = (1..height).map { [nil] * width }

          # Fill in matches
          if @matches
            @matches.each do |pos, string|
              row, col = pos
              string.chars.to_a.each do |char|
                raise ArgumentError.new("overlapping match: #{[pos, string].inspect}") if grid[row][col]
                grid[row][col] = char
                col += 1
              end
            end
          end

          # Fill in ignore overrides
          if @ignore
            @ignore.each do |row, col_range|
              row, col_range = rel_pos([row, col_range])
              col_range.each do |col|
                grid[row][col] = nil
              end
            end
          end

          # Fill in fields, possibly overwriting matches
          if @fields
            @explicit_fields = []
            @implicit_fields_by_row = {}
            @fields.each_with_index do |f, i|
              name, row, col_range = f
              first_col = col_range.first
              explicit = false
              if first_col > 0 and grid[row][first_col-1] == :field   # adjacent fields
                explicit = true
              elsif !@force_fields
                col_range.each do |col|
                  if grid[row][col]
                    explicit = true
                    break
                  end
                end
              end
              if explicit
                @explicit_fields << [name, [row, first_col], col_range.count]   # [name, pos, length]
              else
                @implicit_fields_by_row[row] ||= []
                @implicit_fields_by_row[row] << name
                col_range.each do |col|
                  grid[row][col] = :field
                end
              end
            end
            @explicit_fields = nil if @explicit_fields.empty?
            @implicit_fields_by_row = nil if @implicit_fields_by_row.empty?
          end

          # Fill in the cursor, possibly overwriting matches (but never fields)
          if @cursor_pos
            row, col = @cursor_pos
            if !grid[row][col]
              grid[row][col] = :cursor
            elsif @force_cursor and grid[row][col] != :field and (!@force_cursor.is_a?(Regexp) or @force_cursor =~ grid[row][col])
              grid[row][col] = :cursor
            end
          end

          # Walk the grid, checking for nil, :field, and :cursor.  We won't
          # generate characters for ones that aren't present.
          has_ignore = has_field = has_cursor = false
          height.times do |row|
            width.times do |col|
              if grid[row][col].nil?
                has_ignore = true
              elsif grid[row][col] == :field
                has_field = true
              elsif grid[row][col] == :cursor
                has_cursor = true
              end
            end
          end
          @char_ignore = nil unless has_ignore
          @char_field = nil unless has_field
          @char_cursor = nil unless has_cursor

          # Determine which characters were already used
          @used_chars = Set.new
          @used_chars << @char_ignore if @char_ignore
          @used_chars << @char_field if @char_field
          @used_chars << @char_cursor if @char_cursor
          height.times do |row|
            width.times do |col|
              if grid[row][col] and grid[row][col].is_a?(String)
                @used_chars << grid[row][col]
              end
            end
          end

          # Choose a character to represent ignored positions
          if has_ignore and !@char_ignore
            IGNORE_CHAR_CHOICES.each do |char|
              next if @used_chars.include?(char)
              @char_ignore = char
              break
            end
            raise ArgumentError.new("Could not auto-select char_ignore") unless @char_ignore
            @used_chars << @char_ignore
          end

          # Choose a character to represent the cursor
          if has_cursor and !@char_cursor
            CURSOR_CHAR_CHOICES.each do |char|
              next if @used_chars.include?(char)
              @char_cursor = char
              break
            end
            raise ArgumentError.new("Could not auto-select char_cursor") unless @char_cursor
            @used_chars << @char_cursor
          end

          # Choose a character to represent fields
          if has_field and !@char_field
            FIELD_CHAR_CHOICES.each do |char|
              next if @used_chars.include?(char)
              @char_field = char
              break
            end
            raise ArgumentError.new("Could not auto-select char_field") unless @char_field
            @used_chars << @char_field
          end

          # Walk the grid and fill in the placeholders
          height.times do |row|
            width.times do |col|
              if grid[row][col].nil?
                grid[row][col] = @char_ignore
              elsif grid[row][col] == :field
                grid[row][col] = @char_field
              elsif grid[row][col] == :cursor
                grid[row][col] = @char_cursor
              elsif !grid[row][col].is_a?(String)
                raise "BUG: grid[#{row}][#{col}] #{grid[row][col].inspect}"
              elsif [@char_cursor, @char_field].include?(grid[row][col])
                grid[row][col] = @char_ignore
              end
            end
          end

          @text_lines = []
          @text_lines << "+" + "-"*width + "+"
          height.times do |row|
            grid_row = "|" + grid[row].join + "|"
            if @implicit_fields_by_row and @implicit_fields_by_row[row]
              grid_row += " " + encode_tuple(@implicit_fields_by_row[row])
            end
            @text_lines << grid_row
          end
          @text_lines << "+" + "-"*width + "+"
        end

        def encode_tuple(t)
          "(" + t.map{|v|
            if v.is_a?(Integer)
              v.to_s
            elsif v.is_a?(String)
              encode_string(v)
            elsif v.is_a?(Array)
              encode_tuple(v)
            else
              raise "BUG: encode_tuple(#{t.inspect}) on #{v.inspect}"
            end
          }.join(", ") + ")"
        end

        def encode_string(v)
          r = ['"']
          v.split("").each { |c|
            if c =~ /\A#{Parser::STR_UNESCAPED}\Z/no
              r << c
            else
              r << sprintf("\\%03o", c.unpack("C*")[0])
            end
          }
          r << '"'
          r.join
        end

        def load_spec(name, properties)
          properties = properties.dup
          properties.keys.each do |k|   # Replace symbol keys with strings
            properties[k.to_s] = properties.delete(k)
          end

          # Check name
          raise ArgumentError.new("illegal name") unless name =~ /\A#{Parser::IDENTIFIER}\Z/no
          @name = name

          # position [row, column]
          if properties["position"]
            @position = properties.delete("position").dup
            unless @position.is_a?(Array) and @position.length == 2 and @position.map{|v| v.is_a?(Integer) and v >= 0}.all?
              raise ArgumentError.new("bad 'position' entry: #{@position.inspect}")
            end
          end

          # size [rows, columns]
          if properties["size"]
            @size = properties.delete("size").dup
            unless @size.is_a?(Array) and @size.length == 2 and @size.map{|v| v.is_a?(Integer) and v >= 0}.all?
              raise ArgumentError.new("bad 'size' entry: #{@size.inspect}")
            end
          else
            raise ArgumentError.new("'size' is required")
          end

          # cursor_pos [row, column]
          if properties["cursor_pos"]
            @cursor_pos = properties.delete("cursor_pos")
            unless @cursor_pos.is_a?(Array) and @cursor_pos.length == 2 and @cursor_pos.map{|n| n.is_a?(Integer)}.all?
              raise ArgumentError.new("Illegal cursor_pos")
            end
            @cursor_pos = rel_pos(@cursor_pos)
            unless @cursor_pos[0] >= 0 and @cursor_pos[1] >= 0
              raise ArgumentError.new("cursor_pos out of range")
            end
          end

          # fields {"name" => [row, column_range]}
          if properties["fields"]
            fields = []
            pfields = {}
            properties.delete("fields").each_pair do |name, range|
              pfields[name.to_s] = range    # convert symbols to strings
            end
            pfields.each_pair do |name, range|
              unless range.is_a?(Array) and range.length == 2 and range[0].is_a?(Integer) and range[1].is_a?(Range)
                raise ArgumentError.new("field #{name.inspect} should be [row, col0..col1], not #{range.inspect}")
              end
              row, col_range = range
              unless col_range.first >= 0 and col_range.last >= 0
                raise ArgumentError.new("field #{name.inspect} should contain positive column range, not #{col_range.inspect}")
              end
              row, col_range = rel_pos([row, col_range])
              fields << [name, row, col_range]
            end
            @fields = fields.sort{|a,b| [a[1], a[2].first] <=> [b[1], b[2].first]}    # sort fields in screen order
            @fields = nil if @fields.empty?
          end

          # matches [pos, string]
          if properties["matches"]
            @matches = []
            properties.delete("matches").each do |m|
              unless (m.is_a?(Array) and m.length == 2 and m[0].is_a?(Array) and
                      m[0].length == 2 and m[0].map{|v| v.is_a?(Integer)}.all? and
                      m[1].is_a?(String))
                raise ArgumentError.new("bad 'matches' entry: #{m.inspect}")
              end
              pos, string = m
              pos = rel_pos(pos)
              unless pos[0] >= 0 and pos[1] >= 0
                raise ArgumentError.new("'matches' entry out of range: #{m.inspect}")
              end
              @matches << [pos, string]
            end
            @matches.sort!{|a,b| a[0] <=> b[0]}   # sort matches in screen order
          end

          if properties['char_cursor']
            @char_cursor = properties.delete("char_cursor")
            @char_cursor = Multibyte::Chars.new(@char_cursor).normalize(:c).to_a.join   # Unicode Normalization Form C (NFC)
            raise ArgumentError.new("char_cursor must be 1 character") unless @char_cursor.chars.to_a.length == 1
          end

          if properties['char_field']
            @char_field = properties.delete("char_field")
            @char_field = Multibyte::Chars.new(@char_field).normalize(:c).to_a.join   # Unicode Normalization Form C (NFC)
            raise ArgumentError.new("char_field must be 1 character") unless @char_field.chars.to_a.length == 1
            raise ArgumentError.new("char_field conflicts with char_cursor") if @char_field == @char_cursor
          end

          if properties['char_ignore']
            @char_ignore = properties.delete("char_ignore")
            @char_ignore = Multibyte::Chars.new(@char_ignore).normalize(:c).to_a.join   # Unicode Normalization Form C (NFC)
            raise ArgumentError.new("char_ignore must be 1 character") unless @char_ignore.chars.to_a.length == 1
            raise ArgumentError.new("char_ignore conflicts with char_cursor") if @char_ignore == @char_cursor
            raise ArgumentError.new("char_ignore conflicts with char_field") if @char_ignore == @char_field
          end

          raise ArgumentError.new("extraneous properties: #{properties.keys.inspect}") unless properties.empty?
        end

        # Convert an absolute [row,column] or [row, col1..col2] into a relative position or range.
        def rel_pos(absolute_pos)
          screen_pos = @position || [0,0]
          if absolute_pos[1].is_a?(Range)
            [absolute_pos[0]-screen_pos[0], absolute_pos[1].first-screen_pos[1]..absolute_pos[1].last-screen_pos[1]]
          else
            [absolute_pos[0]-screen_pos[0], absolute_pos[1]-screen_pos[1]]
          end
        end
    end
  end
end
