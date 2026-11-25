# tests/e2e/log-trace-ids.sh (#279): a one-file Rails app with Rails' own tagged logger on
# stdout. The e2e puts the golden tracing.rb at config/initializers/opentelemetry.rb (where the
# generator writes it for Rails, loaded during initialize!) and replaces the line after
# "log tags" with the config.log_tags line /otel-instrument prints.
require 'rails'
require 'action_controller/railtie'
require 'rackup'

class OrdersApp < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.secret_key_base = 'test-only'
  config.hosts.clear
  config.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))
  config.log_level = :info
  # log tags
  # (the printed line goes here)
end

class OrdersController < ActionController::Base
  def show
    Rails.logger.info("rails order line id=#{params[:id]}")
    render plain: "order #{params[:id]}"
  end

  def health
    render plain: 'ok'
  end
end

OrdersApp.initialize!
OrdersApp.routes.draw do
  get '/health', to: 'orders#health'
  get '/orders/:id', to: 'orders#show'
end
Rackup::Server.start(app: OrdersApp, Host: '127.0.0.1', Port: ENV.fetch('PORT', '8971').to_i, server: 'puma')
