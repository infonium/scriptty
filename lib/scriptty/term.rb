# = Generic interface to terminal emulators
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
  module Term
    TERMINAL_TYPES = {
      "dg410" => {:require => "scriptty/term/dg410", :class_name => "::ScripTTY::Term::DG410"},
      "xterm" => {:require => "scriptty/term/xterm", :class_name => "::ScripTTY::Term::XTerm"},
    }

    # Load and instantiate the specified terminal by name
    def self.new(name, *args, &block)
      self.class_by_name(name).new(*args, &block)
    end

    # Load the specified terminal class by name
    def self.class_by_name(name)
      tt = TERMINAL_TYPES[name]
      return nil unless tt
      require tt[:require]
      eval(tt[:class_name])
    end
  end
end

