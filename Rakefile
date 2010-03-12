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
