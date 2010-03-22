begin
  require 'jeweler'
  Jeweler::Tasks.new do |gemspec|
    gemspec.name = "scriptty"
    gemspec.summary = "write expect-like script to control full-screen terminal-based applications"
    gemspec.description = <<EOF
ScripTTY is a JRuby application and library that lets you control full-screen
terminal applications using an expect-like scripting language and a full-screen
matching engine.
EOF
    gemspec.platform = "java"
    gemspec.email = "dlitz@infonium.ca"
    gemspec.homepage = "http://github.com/infonium/scriptty"
    gemspec.authors = ["Dwayne Litzenberger"]
    gemspec.add_dependency "treetop"
    gemspec.add_dependency "multibyte"
  end
rescue LoadError
  puts "Jeweler not available. Install it with: gem install jeweler"
end

require 'rake/rdoctask'
Rake::RDocTask.new do |t|
  t.rdoc_files = Dir.glob(%w( README* COPYING* lib/**/*.rb *.rdoc )).uniq
  t.main = "README.rdoc"
  t.title = "ScripTTY - RDoc Documentation"
  t.options = %w( --charset -UTF-8 --line-numbers )
end

require 'rake/testtask'
Rake::TestTask.new(:test) do |t|
  t.pattern = 'test/**/*_test.rb'
end

begin
  require 'rcov/rcovtask'
  Rcov::RcovTask.new do |t|
    t.pattern = 'test/**/*_test.rb'
    t.rcov_opts = ['--text-report', '--exclude', 'gems,rcov,jruby.*,\(eval\)']
  end
rescue LoadError
  $stderr.puts "warning: rcov not installed; coverage testing not available."
end
