#!/usr/bin/env jruby

$LOAD_PATH.unshift File.dirname(__FILE__) + "/../lib"
require 'rubygems'
require 'scriptty/term/xterm'

t = ScripTTY::Term::XTerm.new
print "\ec"   # reset
delay = ARGV[1] ? ARGV[1].to_f : 0.001
File.read(ARGV[0] || "captures/xterm-overlong-line-prompt.bin").split("").each { |byte|
  t.feed_byte(byte)
  print "\e[H" + t.text.join("\n") + "\n"
  row, col = t.cursor_pos
  print "\e[#{row+1};#{col+1}H"
  $stdout.flush
  if delay > 0
    sleep delay
  end
}
