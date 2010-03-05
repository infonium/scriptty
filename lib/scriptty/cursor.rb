# = Cursor object
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
  class Cursor
    attr_accessor :row, :column
    def initialize
      @row = 0
      @column = 0
    end

    def pos
      [@row, @column]
    end

    def pos=(value)
      raise TypeError.new("must be 2-element array") unless value.is_a?(Array) and value.length == 2
      @row, @column = value
      @row ||= 0
      @column ||= 0
      value
    end
  end
end
