#! /usr/bin/env ruby
# frozen_string_literal: true

#
# check-puppet-last-run
#
# DESCRIPTION:
#   Check the last time puppet was last run
#
# OUTPUT:
#   plain-text
#
# PLATFORMS:
#   Linux
#
# DEPENDENCIES:
#   gem: sensu-plugin
#
# USAGE:
#   Critical if last run is greater than
#
#   check-puppet-last-run-report --report-file /opt/puppetlabs/puppet/cache/state/last_run_report.yaml --warn-age 3600 --crit-age 7200
#
# NOTES:
#
# LICENSE:
#   Copyright 2014 Sonian, Inc. and contributors. <support@sensuapp.org>
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#

require 'sensu-plugins-puppet'
require 'sensu-plugin/check/cli'
require 'yaml'
require 'json'
require 'time'

class PuppetLastRun < Sensu::Plugin::Check::CLI
  option :report_file,
         short: '-f PATH',
         long: '--report-file PATH',
         default: SensuPluginsPuppet::REPORT_FILE,
         description: 'Location of last_run_report.yaml file'

  option :warn_age,
         short: '-w N',
         long: '--warn-age SECONDS',
         default: 3600,
         proc: proc(&:to_i),
         description: 'Age in seconds to be a warning'

  option :crit_age,
         short: '-c N',
         long: '--crit-age SECONDS',
         default: 7200,
         proc: proc(&:to_i),
         description: 'Age in seconds to be a critical'

  option :agent_disabled_file,
         short: '-a PATH',
         long: '--agent-disabled-file PATH',
         default: SensuPluginsPuppet::AGENT_DISABLED_FILE,
         description: 'Path to agent disabled lock file'

  option :disabled_age_limits,
         short: '-d',
         long: '--disabled-age-limits',
         boolean: true,
         default: false,
         description: 'Consider disabled age limits, otherwise use main limits'

  option :warn_age_disabled,
         short: '-W N',
         long: '--warn-age-disabled SECONDS',
         default: 3600,
         proc: proc(&:to_i),
         description: 'Age in seconds to warn when agent is disabled'

  option :crit_age_disabled,
         short: '-C N',
         long: '--crit-age-disabled SECONDS',
         default: 7200,
         proc: proc(&:to_i),
         description: 'Age in seconds to crit when agent is disabled'

  option :report_restart_failures,
         short: '-r',
         long: '--report-restart-failures',
         boolean: true,
         default: false,
         description: 'Raise alerts if restart failures have happened'

  option :ignore_failures,
         short: '-i',
         long: '--ignore-failures',
         boolean: true,
         default: false,
         description: 'Ignore Puppet failures'

  def run
    unless File.exist?(config[:report_file])
      unknown "File #{config[:report_file]} not found"
    end

    @now = Time.now.to_i
    @failures = 0
    @restart_failures = 0

    begin
      report_file = YAML.parse(File.read(config[:report_file]))
      # nuke the yaml document tag that sets the ruby object
      report_file.root.tag = ''
      report = report_file.root.to_ruby
      if report['time']
        @last_run = Time.parse(report['time']).to_i
      else
        critical "#{config[:report_file]} is missing information about the last run timestamp"
      end

      metrics = report['metrics']
      unless metrics
        critical "#{config[:report_file]} is missing report metrics"
      end

      events = metrics['events']
      resources = metrics['events']

      unless config[:ignore_failures]
        if events
          @failures = report_value(events, 'failure')
        else
          critical "#{config[:report_file]} is missing information about the events"
        end

        if config[:report_restart_failures]
          if resources
            @restart_failures = report_value(resources, 'failed_to_restart')
          else
            critical "#{config[:report_file]} is missing information about the resources"
          end
        end
      end
    rescue StandardError
      unknown "Could not process #{config[:summary_file]}"
    end

    @message = "Puppet last run #{formatted_duration(@now - @last_run)} ago"

    if File.exist?(config[:agent_disabled_file])
      begin
        disabled_message = JSON.parse(File.read(config[:agent_disabled_file]))['disabled_message']
        @message += " (disabled reason: #{disabled_message})"
      rescue StandardError => e
        unknown "Could not get disabled message. Reason: #{e.message}"
      end
    end

    if @failures > 0 # rubocop:disable Style/NumericPredicate
      @message += " with #{@failures} failures"
    end

    if @restart_failures > 0 # rubocop:disable Style/NumericPredicate
      @message += " with #{@restart_failures} restart failures"
    end

    if config[:disabled_age_limits] && File.exist?(config[:agent_disabled_file])
      if @now - @last_run > config[:crit_age_disabled]
        critical @message
      elsif @now - @last_run > config[:warn_age_disabled]
        warning @message
      else
        ok @message
      end
    end

    if @now - @last_run > config[:crit_age] || @failures > 0 || @restart_failures > 0 # rubocop:disable Style/NumericPredicate
      critical @message
    elsif @now - @last_run > config[:warn_age]
      warning @message
    else
      ok @message
    end
  end

  def report_value(list, name)
    value = 0
    if list
      list['values'].each do |v|
        if v[0] == name
          value = v[2].to_i
          break
        end
      end
    else
      critical "#{config[:report_file]} is missing information."
    end
    value
  end

  def formatted_duration(total_seconds)
    hours = total_seconds / (60 * 60)
    minutes = (total_seconds / 60) % 60
    seconds = total_seconds % 60

    if hours <= 0 && minutes > 0 # rubocop:disable Style/NumericPredicate
      "#{minutes}m #{seconds}s"
    elsif minutes <= 0
      "#{seconds}s"
    else
      "#{hours}h #{minutes}m #{seconds}s"
    end
  end
end
