puts "Logging in..."
expect("login:")
send("#{@username}\n")
expect("Password:")
send("#{@password}\n")
expect(":~$")   # prompt
send("export TERM=xterm\n")
send("clear\n")
