begin
  require 'sinatra/base'
  require 'scriptty/request_dispatcher'
  require 'scriptty/util/transcript/writer'
  require 'optparse'
rescue LoadError
  retry if require 'rubygems'   # try loading rubygems (only once) if necessary
  raise
end

##
## Parse command line
##

options = {}
OptionParser.new do |opts|
  opts.banner = "#{opts.program_name} [options] HOST [PORT]"
  opts.separator "RequestDispatcher demo"
  opts.separator ""
  opts.on("-u", "--user NAME", "Set login username") do |optarg|
    options[:user] = optarg
  end
  opts.on("-p", "--password PASSWORD", "Set login password") do |optarg|
    options[:password] = optarg
  end
  opts.on("--password-file FILE", "Read password from FILE") do |optarg|
    options[:password] = File.read(optarg).strip.split("\n").first.strip
  end
  opts.on("-o", "--output FILE", "Write transcript to FILE") do |optarg|
    options[:output] = optarg
  end
  opts.on("-a", "--append", "Append to transcript instead of overwriting") do |optarg|
    options[:append] = optarg
  end
end.parse!

host, port = ARGV
unless host
  $stderr.puts "error: No host specified"
  exit 1
end
port ||= 23   # Default port 23

##
## Set up dispatcher
##
t_writer = options[:output] && ScripTTY::Util::Transcript::Writer.new(File.open(options[:output], options[:append] ? "a" : "w"))
DISPATCHER = ScripTTY::RequestDispatcher.new
DISPATCHER.after_init(:call) do |e|
  e.transcript_writer_autoclose = false
  e.transcript_writer = t_writer
  e[:username] = options[:user]
  e[:password] = options[:password]
end
DISPATCHER.after_init do
  load_screens "start_screen.txt"
  load_screens "done_screen.txt"
  load_screens "vim_screen.txt"
  init_term "xterm"
  set_timeout 5.0
  connect [host, port]
  eval_script_file "../telnet-nego.rb"
  eval_script_file "login.rb"
end
DISPATCHER.before_each_request do
  # Set the prompt to place "START" in the bottom-right corner of the screen,
  # and clear the screen.
  send("PS1=$'\\033[24;75HSTART'; clear\n")

  # Wait for the start screen, then ready the prompt to place "DONE" in the
  # bottom-right corner of the screen after the next command executes.
  expect screen(:start_screen)
  send("PS1=$'\\033[24;76HDONE' ; ")
end

# Start the dispatcher thread
DISPATCHER.start

##
## Sinatra webserver configuration
##

class DemoWebServer < Sinatra::Base
  # Show the version of vim installed
  get '/vim/version' do
    version = DISPATCHER.request do
      send("vim\n")
      expect screen(:vim_screen)
      send(":q\n")
      capture["version"].strip
    end
    "Vim version #{version} is installed."
  end

  # Show the vim splash screen
  get '/vim/splash' do
    splash = nil
    DISPATCHER.request do
      send("vim\n")
      expect screen(:vim_screen)
      splash = term.text
      send(":q\n")
    end
    content_type "text/plain", :charset => "UTF-8"
    splash.join("\n")
  end

  # Show the logged in users
  get '/w' do
    screen_lines = nil
    DISPATCHER.request do
      send("clear ; w\n")  # Clear the screen and execute the "w" command
      expect screen(:done_screen)
      screen_lines = term.text    # Capture the screen lines
    end
    content_type "text/plain", :charset => "UTF-8"
    screen_lines.join("\n")
  end

  # Index page with links
  get '/' do
    <<EOF
<html>
<head><title>RequestDispatcher demo</title></head>
<body>
  <h1>RequestDispatcher demo</h1>
  <ul>
    <li><a href="/vim/version">Vim version</a></li>
    <li><a href="/vim/splash">Vim splash screen</a></li>
    <li><a href="/w">Logged in users</a></li>
  </ul>
</body>
</html>
EOF
  end
end

DemoWebServer.run!
