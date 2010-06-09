#
# Copyright (c) 2009 RightScale Inc
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

require 'rubygems'

# Nanite uses the JSON gem, which -- if used in a project that also uses ActiveRecord -- MUST be loaded after
# ActiveRecord in order to ensure that a monkey patch is correctly applied. Since Nanite is designed to be compatible
# with Rails, we tentatively try to load AR here, in case RightLink specs are ever executed in a context where
# ActiveRecord is also loaded.
begin
  require 'active_record'
rescue LoadError => e
  # Make sure we're dealing with a legitimate missing-file LoadError
  raise e unless e.message =~ /^no such file to load/
end

# The daemonize method of AR clashes with the daemonize Chef attribute, we don't need that method so undef it
undef :daemonize if methods.include?('daemonize')

require 'flexmock'
require 'spec'
require 'eventmachine'
require 'fileutils'

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'config', 'right_link_config'))
require File.normalize_path(File.join(File.dirname(__FILE__), '..', 'common', 'lib', 'common'))
require File.normalize_path(File.join(File.dirname(__FILE__), '..', 'payload_types', 'lib', 'payload_types'))
require File.join(File.dirname(__FILE__), 'results_mock')

$:.push File.join(File.dirname( __FILE__), '..', 'actors', 'lib')

config = Spec::Runner.configuration
config.mock_with :flexmock

RightScale::RightLinkLog.init

$TESTING = true
$VERBOSE = nil # Disable constant redefined warning

module RightScale

  module SpecHelpers

    RIGHT_LINK_SPEC_HELPER_TEMP_PATH = File.normalize_path(File.join(RightScale::RightLinkConfig[:platform].filesystem.temp_dir, 'right_link_spec_helper'))

    # Setup instance state for tests
    # Use different identity to reset list of past scripts
    def setup_state(identity = '1')
      cleanup_state
      InstanceState.const_set(:STATE_FILE, state_file_path)
      InstanceState.const_set(:SCRIPTS_FILE, past_scripts_path)
      InstanceState.const_set(:BOOT_LOG_FILE, log_path)
      InstanceState.const_set(:OPERATION_LOG_FILE, log_path)
      InstanceState.const_set(:DECOMMISSION_LOG_FILE, log_path)
      ChefState.const_set(:STATE_FILE, chef_file_path)
      @identity = identity
      @results_factory = ResultsMock.new
      mapper_proxy = flexmock('MapperProxy')
      flexmock(MapperProxy).should_receive(:instance).and_return(mapper_proxy).by_default
      mapper_proxy.should_receive(:request).and_yield(@results_factory.success_results)
      mapper_proxy.should_receive(:push)
      InstanceState.init(@identity)
      RequestForwarder.instance.instance_variable_set(:@running, false)
    end

    # Cleanup files generated by instance state
    def cleanup_state
      delete_if_exists(state_file_path)
      delete_if_exists(chef_file_path)
      delete_if_exists(past_scripts_path)
      delete_if_exists(log_path)
    end

    # Path to serialized instance state
    def state_file_path
      File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '__state.js')
    end

    # Path to serialized instance state
    def chef_file_path
      File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '__chef.js')
    end

    # Path to saved passed scripts
    def past_scripts_path
      File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '__past_scripts.js')
    end

    # Path to instance boot logs
    def log_path
      File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '__nanite.log')
    end

    # Test and delete if exists
    def delete_if_exists(file)
      # Windows cannot delete open files, but we only have a path at this point
      # so it's too late to close the file. report failure to delete files but
      # otherwise continue without failing test.
      begin
        File.delete(file) if File.file?(file)
      rescue Exception => e
        puts "\nWARNING: #{e.message}"
      end
    end

    # Setup location of files generated by script execution
    def setup_script_execution
      Dir.glob(File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '__TestScript*')).should be_empty
      Dir.glob(File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '[0-9]*')).should be_empty
      InstanceConfiguration.const_set(:CACHE_PATH, File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, 'cache'))
    end

    # Cleanup files generated by script execution
    def cleanup_script_execution
      FileUtils.rm_rf(InstanceConfiguration::CACHE_PATH)
    end

    # Create test certificate
    def issue_cert
      test_dn = { 'C'  => 'US',
                  'ST' => 'California',
                  'L'  => 'Santa Barbara',
                  'O'  => 'Nanite',
                  'OU' => 'Certification Services',
                  'CN' => 'Nanite test' }
      dn = DistinguishedName.new(test_dn)
      key = RsaKeyPair.new
      [ Certificate.new(key, dn, dn), key ]
    end

  end # SpecHelpers

end # RightScale

require File.normalize_path(File.join(__FILE__, '..', '..', 'common', 'lib', 'common', 'right_link_log'))

module RightScale
  class RightLinkLog
    # Monkey path RightLink logger to not log by default
    # Define env var RS_LOG to override this behavior and have
    # the logger log normally
    class << self
      alias :original_method_missing :method_missing
    end
    def self.method_missing(m, *args)
      original_method_missing(m, *args) unless [:debug, :info, :warm, :error, :fatal].include?(m)
    end
  end
end

require File.normalize_path(File.join(__FILE__, '..', '..', 'agents', 'lib', 'instance', 'instance_state'))

module RightScale
  class InstanceState
    def self.update_logger
      true
    end
  end
end
