# = Finite state machine for terminal emulation
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

module ScripTTY # :nodoc:
  module Util # :nodoc:
    class FSM
      # Exception for no matching state
      class NoMatch < ArgumentError
        attr_reader :input_sequence, :state
        def initialize(message, input_sequence, state)
          @input_sequence = input_sequence
          @state = state
          super(message)
        end
      end

      # The current (or previous) input.
      attr_reader :input

      # An array of inputs received since the initial state.
      #
      # This allows a callback to get the contents of a complete escape
      # sequence.
      attr_reader :input_sequence

      # The current state
      attr_reader :state

      # The next state
      attr_reader :next_state

      # Object that will receive named events.
      #
      # When processing reaches a named event, the FSM will invoke the method
      # specified by the callback_method attribute (by default, "call"),
      # passing it the name of the event and the FSM object.
      attr_accessor :callback

      # The name of the method to invoke on the callback object. (default: :call)
      attr_accessor :callback_method

      # When not nil, all inputs are redirected, bypassing normal processing
      # (but input_sequence is still updated).
      #
      # If redirect is a symbol, then the specified method is called on the
      # callback object (this implies that the callback object can't be an
      # ordinary Proc in this case).  Otherwise, the "call" method on the
      # redirect object is invoked.
      #
      # The redirect function will be passed a reference to the FSM, which it
      # can use to access methods such as input, input_sequence, reset!, etc.
      #
      # If the redirect function returns true, the process method returns
      # immediately.  If the redirect function returns false, the redirection
      # is removed and the current input is processed normally.
      attr_accessor :redirect

      # Initialize a FSM
      #
      # The following options are supported:
      # [:definition]
      #   FSM definition, as a string
      # [:callback]
      #   See the documentation for the callback attribute.
      #   A block may be given to the new method instead of being passed as an
      #   option.
      # [:callback_method]
      #   See the documentation for the callback_method attribute.
      def initialize(options={}, &block)
        @redirect = nil
        @input_sequence = []
        @callback = options[:callback] || block
        @callback_method = (options[:callback_method] || :call).to_sym
        load_definition(options[:definition])
        reset!
      end

      # Set state and next_state to 1, and clear the redirect.
      def reset!
        @state = 1
        @next_state = 1
        @redirect = nil
        nil
      end

      # Process the specified input.
      #
      # If there is no matching entry in the state transition table,
      # ScripTTY::Util::FSM::NoMatch is raised.
      def process(input)
        # Switch to @next_state
        @state = @next_state

        # Add the input to @input_sequence
        if @state == 1
          @input_sequence = [input]
        else
          @input_sequence << input
        end

        # Set @input and call the redirect object (if necessary)
        @input = input
        if @redirect
          if @redirect.is_a?(Symbol)
            result = @callback.send(@redirect, self)
          else
            result = @redirect.call(self)
          end
          return true if result
          @redirect = nil
        end

        # The redirect function might invoke the reset! method, so fix
        # @input_sequence for that case.
        @input_sequence = [input] if @state == 1

        # Look up for a state transition for the specified input
        t = @state_transitions[@state][input]
        t ||= @state_transitions[@state][:any]
        raise NoMatch.new("No matching transition for input_sequence=#{input_sequence.inspect} (state=#{state.inspect})", input_sequence, state) unless t

        # Set next_state and invoke the callback, if any is specified for this state transition.
        @next_state = t[:next_state]
        if @callback and t[:event]
          @callback.__send__(@callback_method, t[:event], self)
        end

        # Return true
        true
      end

      private

      # Load the specified FSM definition
      def load_definition(definition)
        # NB: We convert the specified state transition table into nested hashes (for faster lookups).
        transitions = {}
        DefinitionParser.new.parse(definition).each do |e|
          state = e.delete(:state)
          input = e.delete(:input)
          raise "BUG" if !state or !input
          e[:event] = e.delete(:event_name).to_sym if e[:event_name]   # Replace string event_name with symbol
          transitions[e[:next_state]] ||= {} if e[:next_state]
          transitions[state] ||= {}
          transitions[state][input] = e
        end
        @state_transitions = transitions
      end
    end
  end
end

require 'scriptty/util/fsm/definition_parser'
