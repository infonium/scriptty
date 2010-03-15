require 'scriptty/apps/capture_app'

module ScripTTY
  module Apps
    class CaptureApp  # reopen
      class Console
        IAC_WILL_ECHO = "\377\373\001"
        IAC_WONT_ECHO = "\377\374\001"
        IAC_DO_ECHO = "\377\375\001"
        IAC_DONT_ECHO = "\377\376\001"

        IAC_WILL_SUPPRESS_GA = "\377\373\003"
        IAC_WONT_SUPPRESS_GA = "\377\374\003"
        IAC_DO_SUPPRESS_GA = "\377\375\003"
        IAC_DONT_SUPPRESS_GA = "\377\376\003"

        def initialize(conn, app)
          @conn = conn
          @app = app
          conn.on_receive_bytes { |bytes| handle_receive_bytes(bytes) }
          conn.on_close { |bytes| handle_close }
          conn.write(IAC_WILL_ECHO + IAC_DONT_ECHO)   # turn echoing off
          conn.write(IAC_WILL_SUPPRESS_GA + IAC_DO_SUPPRESS_GA)   # turn line-buffering off (RFC 858)
          conn.write("\ec") # reset terminal (clear screen; reset attributes)
          @refresh_in_progress = false
          @need_another_refresh = false
          @prompt_input = ""
        end

        def refresh!
          if @refresh_in_progress
            @need_another_refresh = true
            return
          end
          screen_lines = []
          screen_lines << "# #{@prompt_input}"  # prompt
          if @app.term
            screen_lines << "Cursor position: #{@app.term.cursor_pos.inspect}"
            screen_lines << "+" + "-"*@app.term.width + "+"
            @app.term.text.each do |line|
              screen_lines << "|#{line}|"
            end
            screen_lines << "+" + "-"*@app.term.width + "+"
          else
            screen_lines << "[ No terminal ]"
          end
          if @app.respond_to?(:log_messages)
            screen_lines << ""
            @app.log_messages.each do |line|
              screen_lines << ":#{line}"
            end
          end
          output = []
          output << "\e[H"
          output << screen_lines.map{|line| line + "\e[K" + "\r\n"}.join   # erase to end of line after each line
          output << "\e[;#{3+@prompt_input.length}H" # return to prompt
          @refresh_in_progress = true
          @conn.write(output.join) {
            @refresh_in_progress = false
            if @need_another_refresh
              @need_another_refresh = false
              refresh!
            end
          }
          nil
        end

        private

          def handle_receive_bytes(bytes)
            bytes.split("").each do |byte|
              if byte =~ /\A[\x20-\x7e]\Z/m # printable
                @prompt_input << byte
              elsif byte == "\b" or byte == "\x7f"  # backspace or DEL
                @prompt_input = @prompt_input[0..-2] || ""
              elsif byte == "\r"
                handle_command_entered(@prompt_input)
                @prompt_input = ""
              elsif byte == "\n"
                # ignore
              else
                @conn.write("\077") # beep
              end
            end
            refresh!
          end

          def handle_command_entered(cmd)
            @app.handle_console_command_entered(cmd) if @app.respond_to?(:handle_console_command_entered)
          end

          def handle_close
            @app.detach_console(self)
          end
      end
    end
  end
end
