# Copyright (c) 2011 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# RVM pollutes the process environment with garbage that prevents us from activating sandboxed
# RubyGems correctly. Unpollute the environment so our built-in RubyGems can setup the variables
# appropriately for our own usage (and for installation of gems into the sandbox!)
['GEM_HOME', 'GEM_PATH', 'IRBRC', 'MY_RUBY_HOME'].each { |key| ENV.delete(key) }

require 'rubygems'

# Sanity check to make sure all required cross-platform gems are installed. Note
# that this is not a sufficiently thorough check to make sure RightLink will run,
# and is not a  substitute for annotating the right_link gemspec with an accurate
# set of dependencies and dependency-ranges!
gem 'eventmachine'

gem 'right_support'
gem 'right_amqp'
gem 'right_agent'
gem 'right_popen'
gem 'right_http_connection'
gem 'right_scraper'

gem 'ohai'
gem 'chef'

# Sanity check to make sure all required Windows gems are installed.
# Note - can't use RightScale::Platform because gem sources aren't required.
if RUBY_PLATFORM =~ /mswin|mingw/
  gem 'win32-api'
  gem 'windows-api'
  gem 'windows-pr'
  gem 'win32-dir'
  gem 'win32-eventlog'
  gem 'ruby-wmi'
  gem 'win32-process'
  gem 'win32-pipe'
  gem 'win32-open3'
  gem 'win32-service'
  sep = ';'
else
  sep = ':'
end

# Make sure gem bin directories appear at the end of the path so our wrapper
# scripts (e.g. those installed to /usr/bin) get top billing. Notice we choose
# regexp patterns that work under both Linux and Windows.
version = RUBY_VERSION.split('.')[0..1].join('.')
subdir = /(ruby|gems)[\\\/]#{version}[\\\/]bin/
paths = ENV['PATH'].split(/[:;]/)
gem_bin = paths.select { |p| p =~ subdir }
paths.delete_if { |p| p =~ subdir }
ENV['PATH'] = (paths + gem_bin).join(sep)
