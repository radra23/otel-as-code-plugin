# tests/e2e/log-trace-ids.sh (#279): a Sinatra service behind the golden tracing.rb that logs one
# line through its own stdlib Logger while POST /pay is handled. LOG_MODE picks the app's own
# format (plain, json, or Logger's default); the e2e replaces the line after "log setup" with
# the line /otel-instrument prints, read out of the generator.
require 'sinatra'
require 'json'
require 'logger'
require_relative 'tracing'

set :port, ENV.fetch('PORT', '8970').to_i
set :bind, '127.0.0.1'
set :logging, false

logger = Logger.new($stdout)
case ENV['LOG_MODE']
when 'plain' then logger.formatter = proc { |sev, _time, _prog, msg| "APP #{sev} | #{msg}\n" }
when 'json' then logger.formatter = proc { |sev, _time, _prog, msg| { level: sev, msg: msg }.to_json + "\n" }
end
# log setup
# (the printed line goes here)
LOG = logger

get('/health') { 'ok' }

post '/pay' do
  LOG.info('ruby pay line orderId=o1')
  '{"paid":true}'
end
