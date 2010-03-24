load_screens "demo-telnet-session-screens.txt"
init_term "xterm"
set_timeout 5.0
connect ['192.168.3.104', 23]
puts "TELNET negotiation..."
eval_script_file "telnet-nego.rb"

# Login
puts "Logging in..."
expect("login:")
send("dwaynelitzenberger\n")
expect("Password:")
send("secret\n")
expect(":~$")   # prompt
send("export TERM=xterm\n")   # XXX - we should negotiate the terminal type during TELNET negotiation
send("clear\n")

# Mess around in vim
puts "Messing around in vim..."
send("vim\n")
expect screen("dump2")
send("i")
expect screen("dump3")
send("Hello world!\e")
expect screen("dump4")
send(":q!\n")
expect(":~$")   # prompt

# Start iptraf
puts "Messing around in iptraf..."
send("sudo iptraf\n")
expect screen("dump9")
send(" ")
expect screen("dump11")
send("m")
expect screen("dump14")
(0..11).each do |n|
  if match["iface#{n}"].strip == "eth0"
    send("\eOB"*n)
    break
  end
end
send "\r"

# Wait for iptraf main loop to start
expect screen("dump15")

# Exit iptraf
send("x")
expect screen("dump11")
send("x")

puts "Waiting for prompt..."
expect screen("dump16")
puts "Delaying..."
sleep 1
expect screen("dump16")
match['prompt'] =~ /:~\$/

puts "Exiting..."
send("exit\n")
exit
