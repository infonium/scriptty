require 'scriptty/apps/capture_app'

module ScripTTY
  module Apps
    class CaptureApp  # reopen
      class PasswordPrompt
        IAC_WILL_ECHO = "\377\373\001"
        IAC_WONT_ECHO = "\377\374\001"
        IAC_DO_ECHO = "\377\375\001"
        IAC_DONT_ECHO = "\377\376\001"

        def initialize(conn, prompt="Password: ")
          @conn = conn
          @conn.write(IAC_WILL_ECHO + IAC_DONT_ECHO) if prompt    # echo off
          @conn.write(prompt) if prompt
          @conn.on_receive_bytes { |bytes|
            bytes.split("").each { |byte|
              handle_received_byte(byte) unless @done   # XXX - This doesn't work well with pipelining; we throw away bytes after the prompt is finished.
            }
          }
          @password_buffer = ""
          @done = false
        end

        def authenticate(&block)
          raise ArgumentError.new("no block given") unless block
          @authenticate_proc = block
          nil
        end

        def on_fail(&block)
          raise ArgumentError.new("no block given") unless block
          @fail_proc = block
          nil
        end

        def on_success(&block)
          raise ArgumentError.new("no block given") unless block
          @success_proc = block
          nil
        end

        private
          def handle_received_byte(byte)
            @password_buffer << byte
            if byte == "\r" or byte == "\n"
              @done = true
              @conn.write(IAC_DO_ECHO + "\r\n") if @password_buffer =~ /#{Regexp.escape(IAC_DO_ECHO)}|#{Regexp.escape(IAC_WILL_ECHO)}/ # echo on, send newline
              password = @password_buffer
              password.gsub!(/\377[\373-\376]\001/, "")   # Strip IAC DO/DONT/WILL/WONT ECHO from password
              password.chomp!   # strip trailing newline
              if @authenticate_proc.call(password)
                # success
                @success_proc.call if @success_proc
              else
                # Failure
                @fail_proc.call if @fail_proc
              end
            end
            nil
          end
      end
    end
  end
end
