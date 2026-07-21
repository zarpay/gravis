# frozen_string_literal: true

module Gravis
  class Railtie < Rails::Railtie
    # Solid Queue mixes limits_concurrency into Active Job via its own
    # on_load(:active_job) hook; ours must register after it or DispatchJob
    # loads before the mixin exists.
    initializer "gravis.load_job", after: "solid_queue.active_job.extensions" do
      ActiveSupport.on_load(:active_job) do
        require "gravis/dispatch_job"
      end
    end

    # enqueue_at covers `set(wait:)` jobs — the nudge is scheduled for when
    # the job becomes ready.
    initializer "gravis.enqueue_trigger" do
      %w[enqueue.active_job enqueue_at.active_job].each do |event|
        ActiveSupport::Notifications.subscribe(event) do |*, payload|
          Gravis.nudge(payload[:job])
        end
      end
    end

    # We extend an undocumented surface of Solid Queue; if a future version
    # removes it, scream — a silently missing exclusion means wildcard
    # workers claim big jobs onto small boxes.
    initializer "gravis.queue_exclusion" do
      config.to_prepare do
        if defined?(SolidQueue::QueueSelector) &&
            SolidQueue::QueueSelector.public_method_defined?(:scoped_relations)
          require "gravis/queue_exclusion"
          SolidQueue::QueueSelector.prepend(Gravis::QueueExclusion)
        else
          message = "[gravis] SolidQueue::QueueSelector#scoped_relations is gone — " \
                    "queue exclusion cannot be applied; wildcard workers WILL claim gravis jobs. " \
                    "Pin solid_queue to a compatible version or update gravis."
          Rails.logger.error(message)
          Rails.error.report(Gravis::Error.new(message), handled: true, source: "gravis")
        end
      end
    end

    config.after_initialize do
      Gravis.announce_boot(Rails.logger)
      Gravis.recover_pending
    end

    rake_tasks do
      load File.expand_path("tasks/gravis.rake", __dir__)
    end
  end
end
