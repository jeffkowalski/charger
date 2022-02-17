#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

class Charger < ScannerBotBase
  no_commands do
    def main
      credentials = load_credentials

      Mail.defaults do
        delivery_method :smtp, credentials[:mail_delivery_defaults]
      end

      influxdb = InfluxDB::Client.new 'tesla'
      state = {}
      range = {}

      credentials[:cars].each_key do |name|
        @logger.debug "retrieving #{name}"
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
            @logger.info "alerting #{email} to plug in '#{name}'"
            next if options[:dry_run]

            Mail.deliver do
              to email
              from credentials[:sender]
              subject 'Please plug in your car'
              body "Your car has only #{range[name]} miles of range.  Please plug it in to charge."
            end
          end

          break
        end
      end
    end
  end
end

Charger.start
