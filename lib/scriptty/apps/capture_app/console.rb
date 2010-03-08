require 'scriptty/apps/capture_app'

module ScripTTY
  module Apps
    class CaptureApp  # reopen
      class Console
        IAC_WILL_ECHO = "\377\373\001"
        IAC_WONT_ECHO = "\377\374\001"
        IAC_DO_ECHO = "\377\375\001"
        IAC_DONT_ECHO = "\377\376\001"

        def initialize(conn, app)
          @conn = conn
          @app = app
          conn.on_receive_bytes { |bytes| handle_receive_bytes(bytes) }
          conn.on_close { |bytes| handle_close }
          conn.write(IAC_WILL_ECHO + IAC_DONT_ECHO)   # turn echoing off
          conn.write("\ec") # reset terminal (clear screen; reset attributes)
          @refresh_in_progress = false
          @need_another_refresh = false
        end

        def refresh!
          if @refresh_in_progress
            @need_another_refresh = true
            return
          end
          screen_lines = []
          screen_lines << "# "  # prompt
          if @app.term
            screen_lines << "Cursor position: #{@app.term.cursor_pos.inspect}      "
            screen_lines << "+" + "-"*@app.term.width + "+"
            @app.term.text.each do |line|
              screen_lines << "|#{line}|"
            end
            screen_lines << "+" + "-"*@app.term.width + "+"
          else
            screen_lines << "[ No terminal ]"
          end
          output = []
          output << "\e[H"
          output << screen_lines.join("\r\n")
          output << "\e[;3H" # return to prompt
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
            refresh!
          end

          def handle_close
            @app.detach_console(self)
          end
      end
    end
  end
end
