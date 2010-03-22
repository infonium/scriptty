# Telnet negotiation example
#
# NOTE: This would cause an infinite loop if two ends of the connection ran
# this algorithm, but it appears to be safe on the client-side only with a
# smarter server.

# Options we WILL (in response to DO)
supported_will_options = [
  "\000",     # Binary Transmission
  "\003",     # Suppress Go Ahead
]

# Options we DO (in response to WILL)
supported_do_options = [
  "\000",     # Binary Transmission
  "\001",     # Echo
  "\003",     # Suppress Go Ahead
]

# Initial send
supported_do_options.each do |opt|
  send "\377\375#{opt}"   # IAC DO <option>
end
supported_will_options.each do |opt|
  send "\377\373#{opt}"   # IAC WILL <option>
end

done_telnet_nego = false
until done_telnet_nego
  expect {
    on(/\377([\373\374\375\376])(.)/n) { |m|   # IAC WILL/WONT/DO/DONT <option>
      cmd = {"\373" => :will, "\374" => :wont, "\375" => :do, "\376" => :dont}[m[1]]
      opt = m[2]
      puts "IAC #{cmd} #{opt.inspect}"
      if cmd == :do
        if supported_will_options.include?(opt)
          send "\377\373#{opt}"    # IAC WILL <option>
        else
          send "\377\374#{opt}"    # IAC WONT <option>
        end
      elsif cmd == :will
        if supported_do_options.include?(opt)
          send "\377\375#{opt}"    # IAC DO <option>
        else
          send "\377\376#{opt}"    # IAC DONT <option>
        end
      elsif cmd == :dont
        send "\377\374#{opt}"    # IAC WONT <option>
      elsif cmd == :wont
        send "\377\376#{opt}"    # IAC DONT <option>
      end
    }
    on(/[^\377]/n) { puts "DONE"; done_telnet_nego = true }    # We're done TELNET negotiation when we receive something that's not IAC
  }
end
