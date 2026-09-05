# notifications-api — a minimal greenfield Sinatra service.
#
# Carries the one documented /otel-instrument wiring line (placed AFTER the sinatra/json
# loads) — Ruby's instrumentation gems patch already-loaded classes at configure time, so
# tracing must load LAST, not first. The tracing.rb file is dropped in from
# tests/snapshots/instrument/ruby by the e2e harness's run.sh, assembling the instrumented
# state /otel-instrument would leave behind.
require 'sinatra'
require 'json'
require_relative 'tracing'

set :bind, '0.0.0.0'
set :port, ENV.fetch('PORT', 8080).to_i

get '/health' do
  content_type :json
  { status: 'ok' }.to_json
end

get '/notify' do
  content_type :json
  { notified: true }.to_json
end
