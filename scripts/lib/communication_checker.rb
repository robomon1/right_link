# === Synopsis:
#   RightScale Communication Checker (rs_comm_chk)
#   (c) 2010 RightScale
#
#   Checks the instance to see if it is actively communicating with RightNet
#   and if not causes it to re-enroll
#
# === Usage
#    rs_comm_chk
#
#    Options:
#      --attempts, -a N      Override default number of communication check attempts
#      --interval, -i SEC    Override default interval for retrying communication check
#      --time-limit, -t SEC  Override default time limit since last communication
#      --verbose, -v         Display debug information
#      --version             Display version information
#      --help                Display help
#

require 'rubygems'
require 'eventmachine'
require 'optparse'
require 'fileutils'
require 'rdoc/usage'

BASE_DIR = File.join(File.dirname(__FILE__), '..', '..')

require File.expand_path(File.join(BASE_DIR, 'config', 'right_link_config'))
require File.normalize_path(File.join(BASE_DIR, 'common', 'lib', 'common'))
require File.normalize_path(File.join(BASE_DIR, 'command_protocol', 'lib', 'command_protocol'))
require File.normalize_path(File.join(BASE_DIR, 'payload_types', 'lib', 'payload_types'))
require File.normalize_path(File.join(BASE_DIR, 'scripts', 'lib', 'agent_utils'))
require File.normalize_path(File.join(BASE_DIR, 'scripts', 'lib', 'rdoc_patch'))

module RightScale

  class CommunicationChecker

    include Utils

    VERSION = [0, 1]

    # Path to JSON file where current instance state is serialized
    STATE_DIR = RightScale::RightLinkConfig[:agent_state_dir]
    STATE_FILE = File.join(STATE_DIR, 'state.js')

    # Path to log directory
    LOG_DIR = RightLinkConfig[:platform].filesystem.log_dir

    # Minimum seconds since last communication for instance to be considered connected
    LAST_COMMUNICATION_TIME_LIMIT = 12 * 60 * 60

    # Maximum number of seconds between checks for recent communication if first check fails
    CHECK_INTERVAL = 5 * 60

    # Maximum number of seconds to wait for a command response from the instance agent
    COMMAND_TIMEOUT = 2 * 60

    # Maximum number of attempts to check communication before decide to re-enroll
    MAX_ATTEMPTS = 3

    # Time constants
    MINUTE = 60
    HOUR = 60 * MINUTE
    DAY = 24 * HOUR

    # Run communication check
    #
    # === Parameters
    # options(Hash):: Run options
    #   :max_attempts(Integer):: Maximum number of communication check attempts,
    #     defaults to MAX_ATTEMPTS
    #   :time_limit(Integer):: Time limit for last communication,
    #     defaults to LAST_COMMUNICATION_TIME_LIMIT
    #   :check_interval(Integer):: Number of seconds to wait before retrying communication check,
    #     defaults to CHECK_INTERVAL
    #   :verbose(Boolean):: Whether to display debug information
    #
    # === Return
    # true:: Always return true
    def run(options)
      begin
        @options = options
        @agent = agent_options('instance')
        fail("No instance agent configured") if @agent.empty?

        RightLinkLog.program_name = 'RightLink'
        RightLinkLog.log_to_file_only(@agent[:log_to_file_only])
        RightLinkLog.init(@agent[:identity], LOG_DIR)

        EM.error_handler do |e|
          RightLinkLog.error("[check] Failed RightLink communication check internally: #{e}\n" + e.backtrace.join("\n"))
          if e.class == RuntimeError && e.message =~ /no connection/
            reenroll
            exit
          else
            fail("Failed internally: #{e}\n" + e.backtrace.join("\n"))
          end
        end

        EM.run { check_communication(0) }

      rescue SystemExit => e
        raise e
      rescue Exception => e
        fail("Failed to run: #{e}\n" + e.backtrace.join("\n"))
      end
      true
    end

    # Create options hash from command line arguments
    #
    # === Return
    # options(Hash):: Command line options
    def parse_args
      options = {
        :max_attempts   => MAX_ATTEMPTS,
        :check_interval => CHECK_INTERVAL,
        :time_limit     => LAST_COMMUNICATION_TIME_LIMIT,
        :verbose        => false
      }

      opts = OptionParser.new do |opts|

        opts.on('-a', '--attempts N') do |n|
          options[:max_attempts] = n.to_i
        end

        opts.on('-i', '--interval SEC') do |sec|
          options[:check_interval] = sec.to_i
        end

        opts.on('-t', '--time-limit SEC') do |sec|
          options[:time_limit] = sec.to_i
        end

        opts.on('-v', '--verbose') do
          options[:verbose] = true
        end

      end

      opts.on_tail('--version') do
        puts version
        exit
      end

      opts.on_tail('--help') do
         RDoc::usage_from_file(__FILE__)
         exit
      end

      begin
        opts.parse!(ARGV)
      rescue SystemExit => e
        raise e
      rescue Exception => e
        fail("#{e}\nUse --help for additional information")
      end
      options
    end

protected

    # Check communication, repeatedly if necessary
    #
    # === Parameters
    # attempt(Integer):: Number of attempts thus far
    #
    # === Return
    # true:: Always return true
    def check_communication(attempt)
      attempt += 1
      begin
        if (time = time_since_last_communication) <= @options[:time_limit]
          @timer.cancel if @timer
          elapsed = elapsed(time)
          RightLinkLog.info("[check] Passed RightLink communication check with activity as recently as #{elapsed} ago")
          puts "Passed communication check with activity as recently as #{elapsed} ago"
          EM.stop
        elsif attempt <= @options[:max_attempts]
          try_communicating(attempt)
          @timer = EM::Timer.new(@options[:check_interval]) do
            RightLinkLog.error("[check] RightLink communication attempt #{attempt} " +
                               "timed out after #{elapsed(@options[:check_interval])}")
            check_communication(attempt)
          end
        else
          reenroll
          EM.stop
        end
      rescue Exception => e
        RightLinkLog.info("[check] Failed RightLink communication check: #{e}\n" + e.backtrace.join("\n"))
        if attempt <= @options[:max_attempts]
          check_communication(attempt)
        else
          fail("Failed communication check: #{e}\n" + e.backtrace.join("\n"))
        end
      end
      true
    end

    # Get elapsed time since last communication
    #
    # === Return
    # (Integer):: Elapsed time
    def time_since_last_communication
      state = JSON.load(File.read(STATE_FILE)) if File.file?(STATE_FILE)
      state.nil? ? (@options[:time_limit] + 1) : (Time.now.to_i - state["last_communication"])
    end

    # Ask instance agent to try to communicate
    #
    # === Parameters
    # attempt(Integer):: Number of attempts thus far
    #
    # === Return
    # true:: Always return true
    def try_communicating(attempt)
      begin
        listen_port = @agent[:listen_port]
        client = CommandClient.new(listen_port, @agent[:cookie])
        client.send_command({:name => "check_connectivity"}, @options[:verbose], COMMAND_TIMEOUT) do |r|
          res = OperationResult.from_results(JSON.load(r)) rescue nil
          if res && res.success?
            RightLinkLog.info("[check] Successful RightLink communication on attempt #{attempt}")
            @timer.cancel if @timer
            check_communication(attempt)
          else
            error = (res && result.content) || "<unknown error>"
            RightLinkLog.error("[check] Failed RightLink communication on attempt #{attempt}: #{error}")
            # Let existing timer control next attempt
          end
        end
      rescue Exception => e
        RightLinkLog.error("[check] Failed to contact agent during RightLink communication check: #{e}\n" +
                           e.backtrace.join("\n"))
      end
      true
    end

    # Trigger re-enroll, exit if fails
    #
    # === Return
    # true:: Always return true
    def reenroll
      begin
        RightLinkLog.info("[check] RightLink communication check initiating re-enroll after failure to communicate")
        cmd = "rs_reenroll"
        cmd += '&' unless Platform.windows?
        system(cmd)
      rescue Exception => e
        RightLinkLog.error("[check] Failed re-enroll during RightLink communication check: #{e}\n" +
                           e.backtrace.join("\n"))
        fail("Failed to re-enroll: #{e}\n" + e.backtrace.join("\n"))
      end
      true
    end

    # Convert elapsed time in seconds to displayable format
    #
    # === Parameters
    # time(Integer|Float):: Elapsed time
    #
    # === Return
    # (String):: Display string
    def elapsed(time)
      time = time.to_i
      if time <= MINUTE
        "#{time} sec"
      elsif time <= HOUR
        minutes = time / MINUTE
        seconds = time - (minutes * MINUTE)
        "#{minutes} min #{seconds} sec"
      elsif time <= DAY
        hours = time / HOUR
        minutes = (time - (hours * HOUR)) / MINUTE
        "#{hours} hr #{minutes} min"
      else
        days = time / DAY
        hours = (time - (days * DAY)) / HOUR
        minutes = (time - (days * DAY) - (hours * HOUR)) / MINUTE
        "#{days} day#{days == 1 ? '' : 's'} #{hours} hr #{minutes} min"
      end
    end

    # Print error on console and exit abnormally
    #
    # === Parameter
    # msg(String):: Error message, default to nil (no message printed)
    # print_usage(Boolean):: Whether script usage should be printed, default to false
    #
    # === Return
    # R.I.P. does not return
    def fail(msg = nil, print_usage = false)
      EM.stop rescue nil
      puts "** #{msg}" if msg
      RDoc::usage_from_file(__FILE__) if print_usage
      exit(1)
    end

    # Version information
    #
    # === Return
    # ver(String):: Version information
    def version
      ver = "rs_comm_chk #{VERSION.join('.')} - RightLink Communication Checker (c) 2009 RightScale"
    end

  end

end

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