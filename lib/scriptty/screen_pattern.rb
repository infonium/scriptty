# = Screen pattern object
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

module ScripTTY
  class ScreenPattern
    class <<self
      # Parse a pattern file and return an array of ScreenPattern objects
      def parse(s, filename=nil, lineno=nil)
        retval = []
        Parser.parse(s, filename, lineno) do |spec|
          retval << new(spec[:name], spec[:properties])
        end
        retval
      end

      def from_term(term, opts={})
        from_text(term.text, {:cursor_pos => term.cursor_pos}.merge(opts))
      end

      def from_text(text, opts={})
        text = text.split(/\r?\n/n) if text.is_a?(String)
        name ||= opts[:name] || "untitled"

        width = text.map{|line| line.chars.to_a.length}.max
        height = text.length
        properties = {}
        properties['cursor_pos'] = opts[:cursor_pos]
        properties['size'] = [height, width]
        properties['matches'] = []
        text.each_with_index{|line, i|
          properties['matches'] << [[i, 0], line]
        }
        new(name, properties)
      end
      protected :new    # Users should not instantiate this object directly
    end

    # The name given to this pattern
    attr_accessor :name

    # The [row, column] of the cursor position (or nil if unspecified)
    attr_accessor :cursor_pos

    def initialize(name, properties)    # :nodoc:
      @name = name
      @position = properties["position"]
      @size = properties["size"]
      @cursor_pos = properties["cursor_pos"]
      @field_ranges = properties["fields"]    # Hash of "field_name" => [row, col1..col2] ranges
      @matches = properties["matches"]  # Array of [[row,col], string] records to match
    end

    def inspect
      "#<#{self.class.name}:#{sprintf("0x%x", object_id)} name=#{@name}>"
    end

    # Match this pattern against a Term object.  If the match succeeds, return
    # the Hash of fields extracted from the screen.  Otherwise, return nil.
    def match_term(term)
      return nil if @cursor_pos and @cursor_pos != term.cursor_pos

      # XXX UNICODE
      if @matches
        text = term.text
        @matches.each do |pos, str|
          row, col = pos
          col_range = col..col+str.length-1
          return nil unless text[row][col_range] == str
        end
      end

      fields = {}
      if @field_ranges
        @field_ranges.each_pair do |k, range|
          row, col_range = range
          fields[k] = text[row][col_range]
        end
      end
      fields
    end

    def generate
      Generator.generate(@name, :cursor_pos => @cursor_pos, :matches => @matches, :fields => @field_ranges, :position => @position, :size => @size)
    end
  end
end

require 'scriptty/screen_pattern/parser'
require 'scriptty/screen_pattern/generator'
