# = autowatchr script for continuous testing of ScripTTY
# == Instructions
# - Install the 'watchr' and 'autowatchr' gems
# - Run "watchr test.watchr"

require 'autowatchr'

# Fixup mapping between files in lib/ and corresponding tests in test/
class ::Autowatchr  # reopen
  # Take a path like "lib/scriptty/foo/bar.rb" and run the corresponding test "test/foo/bar_test.rb"
  def run_lib_file(path)
    path_segments = path.split(File::SEPARATOR).reject{|s| s.empty?}
    basename = path_segments.pop
    path_segments.shift   # Remove "lib"
    path_segments.shift   # Remove "scriptty"
    path_segments.unshift @config.test_dir  # Prepend "test"
    path_segments << basename.gsub(/\.rb\Z/, "") + "_test.rb"    # append test name
    run_test_file(File.join(*path_segments))
  end
end

Autowatchr.new(self) do |config|
  config.ruby = ENV['RUBY'] || 'ruby'
  config.lib_dir = 'lib'
  config.test_dir = 'test'
  config.test_re = /^.*_test\.rb\Z/
end

# vim:set ft=ruby:
