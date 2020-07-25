#!/usr/bin/env ruby
# frozen_string_literal: true

require 'influxdb'
require 'mail'
require 'yaml'

CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'charger.yaml')

credentials = YAML.load_file CREDENTIALS_PATH

Mail.defaults do
  delivery_method :smtp, credentials['mail_delivery_defaults']
end

influxdb = InfluxDB::Client.new 'tesla'
state = {}
range = {}

credentials['cars'].keys.each do |name|
  result = influxdb.query "select last(value) from charging_state where display_name='#{name}'"
  state[name] = result[0]['values'][0]['last']
  result = influxdb.query "select last(value) from est_battery_range where display_name='#{name}'"
  range[name] = result[0]['values'][0]['last'].to_f
end
credentials['cars'].each do |name, emails|
  next unless range[name] < 100 && state[name] == 'Disconnected'

  (credentials['cars'].keys - [name]).each do |other|
    next unless state[other] == 'Disconnected' || state[other] == 'Complete' ||
                (state[other] == 'Stopped' && range[other] > 100)

    emails.each do |email|
      Mail.deliver do
        to email
        from credentials['sender']
        subject 'Please plug in your car'
        body "Your car has only #{range[name]} miles of range.  Please plug it in to charge."
      end
    end
    break
  end
end
