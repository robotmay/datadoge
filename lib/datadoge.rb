require 'datadoge/version'
require 'gem_config'
require 'statsd'

module Datadoge
  include GemConfig::Base

  with_configuration do
    has :environments, classes: Array, default: ['production']
    has :tags, classes: Array, default: ["host:#{ENV['INSTRUMENTATION_HOSTNAME']}"]
    has :metric, classes: [Symbol, String], default: 'Performance'
  end

  class Railtie < Rails::Railtie
    initializer "datadoge.configure_rails_initialization" do |app|
      $statsd = Statsd.new

      ActiveSupport::Notifications.subscribe /process_action.action_controller/ do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        controller = "controller:#{event.payload[:controller]}"
        action = "action:#{event.payload[:action]}"
        controller_action = "controller_action:#{event.payload[:controller]}##{event.payload[:action]}"
        format = "format:#{event.payload[:format] || 'all'}"
        format = "format:all" if format == "format:*/*"
        status = event.payload[:status]
        tags = [controller, action, controller_action, format] + Datadoge.configuration.tags
        ActiveSupport::Notifications.instrument "performance", :action => :timing, :tags => tags, :measurement => "request.total_duration", :value => event.duration
        ActiveSupport::Notifications.instrument "performance", :action => :timing, :tags => tags, :measurement => "database.query.time", :value => event.payload[:db_runtime]
        ActiveSupport::Notifications.instrument "performance", :action => :timing, :tags => tags, :measurement => "web.view.time", :value => event.payload[:view_runtime]
        ActiveSupport::Notifications.instrument "performance", :tags => tags,  :measurement => "request.status.#{status}"
      end

      ActiveSupport::Notifications.subscribe /performance/ do |name, start, finish, id, payload|
        send_event_to_statsd(name, payload) if Datadoge.configuration.environments.include?(Rails.env)
      end

      def send_event_to_statsd(name, payload)
        action = payload[:action] || :increment
        measurement = payload[:measurement]
        value = payload[:value]
        tags = payload[:tags]
        key_name = "#{Datadoge.configuration.metric.to_s}.#{measurement}"
        if action == :increment
          $statsd.increment key_name, :tags => tags
        else
          $statsd.histogram key_name, value, :tags => tags
        end
      end
    end
  end
end
