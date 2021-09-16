#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'influxdb'
require 'logger'
require 'mail'
require 'thor'
require 'yaml'

LOGFILE = File.join(Dir.home, '.log', 'charger.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'charger.yaml')

class Charger < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new $stdout
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  desc 'scan', ''
  method_option :dry_run, type: :boolean, aliases: '-n', desc: "don't log to database"
  def scan
    setup_logger

    credentials = YAML.load_file CREDENTIALS_PATH

    Mail.defaults do
      delivery_method :smtp, credentials[:mail_delivery_defaults]
    end

    influxdb = InfluxDB::Client.new 'tesla'
    state = {}
    range = {}

    credentials[:cars].each_key do |name|
      result = influxdb.query "select last(value) from charging_state where display_name='#{name}'"
      state[name] = result[0]['values'][0]['last']
      result = influxdb.query "select last(value) from est_battery_range where display_name='#{name}'"
      range[name] = result[0]['values'][0]['last'].to_f
    end

    credentials[:cars].each do |name, prefs|
      @logger.info "'#{name}' is #{state[name]} with #{range[name]} miles"
      next unless range[name] < prefs[:limit] && state[name] == 'Disconnected'

      (credentials[:cars].keys - [name]).each do |other|
        @logger.info "(other) '#{other}' is #{state[other]}"
        next unless state[other] == 'Disconnected' || state[other] == 'Complete' ||
                    (state[other] == 'Stopped' && credentials[:cars][other][:limit] > 100)

        prefs[:notify].each do |email|
          Mail.deliver do
            to email
            from credentials[:sender]
            subject 'Please plug in your car'
            body "Your car has only #{range[name]} miles of range.  Please plug it in to charge."
          end
        rescue StandardError => e
          @logger.error e
        end

        break
      end
    end
  end

  default_task :scan
end

Charger.start
