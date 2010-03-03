# FSM definition parser
# Copyright (C) 2010  Infonium Inc
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

require 'treetop'

Treetop.load File.join(File.dirname(__FILE__), "scriptty_fsm_definition.treetop")

module ScripTTY
  module Util
    class FSM
      class DefinitionParser
        # Returns an array of hashes representing the state transition table
        # for a given FSM definition.
        #
        # Each table entry has the following keys:
        # [:state]
        #   The state to which the entry applies.  State 1 is the starting state.
        # [:input]
        #   The input used to match this entry, or the symbol :any.  The :any
        #   input represents any input that does not match a more specific entry.
        # [:event_name]
        #   The name to be passed to the callback when this entry is reached.
        #   May be nil.
        # [:next_state]
        #   The next state to move to after the callback is invoked.
        #   Note that the callback might modify this variable.
        def parse(definition)
          parser = ScripTTYFSMDefinitionParser.new
          parse_tree = parser.parse(definition + "\n")    # The grammar requires a newline at the end of the file, so make sure it's there.
          raise ArgumentError.new(parser.failure_reason) unless parse_tree
          state_transition_table = []
          load_recursive(state_transition_table, parse_tree, :start, {})
          normalize_state_transition_table(state_transition_table)
          state_transition_table
        end

        private

        def load_recursive(ttable, t, state, dupcheck_hash)  # :nodoc:
          t.rules.each do |rule|
            # Use object_id to identify the state.  This will be replaced in
            # normalize_state_transition_table() by something more readable and
            # consistent.
            next_state = rule.sub_list ? rule.sub_list.object_id : :start
            if rule.lhs.respond_to? :cc_values
              # Character class (multiple equivalent inputs)
              rule.lhs.cc_values.each do |value|
                dup_check(dupcheck_hash, rule, state, value)
                ttable << {:state => state, :input => value, :next_state => next_state, :event_name => rule.event_name}
              end
            else
              # Single input
              dup_check(dupcheck_hash, rule, state, rule.lhs.value)
              ttable << {:state => state, :input => rule.lhs.value, :next_state => next_state, :event_name => rule.event_name}
            end
            if next_state != :start
              load_recursive(ttable, rule.sub_list, next_state, dupcheck_hash)
            end
          end
          nil
        end

        def normalize_state_transition_table(ttable)
          states = {}
          n = 0
          normalize_state = Proc.new {|s|
            if states[s]
              states[s]
            else
              states[s] = (n += 1)
            end
          }
          normalize_state.call(:start)    # Assign state 1 to the initial state
          ttable.each do |row|
            row[:state] = normalize_state.call(row[:state]) if row[:state]
            row[:next_state] = normalize_state.call(row[:next_state]) if row[:next_state]
          end
          nil
        end

        def dup_check(dupcheck_hash, rule, state, input)  # :nodoc:
          k = [state, input]
          current_linenum = rule.input[0,rule.lhs.interval.first].split("\n", -1).length
          current_line = rule.input[rule.interval].chomp
          prev_linenum, prev_line = dupcheck_hash[k]
          if prev_linenum
            # Calculate the line number
            raise ArgumentError.new("rule conflict\nline #{prev_linenum}: #{prev_line}\nline #{current_linenum}: #{current_line}")
          end
          dupcheck_hash[k] = [current_linenum, current_line]
          nil
        end
      end
    end
  end
end
