# frozen_string_literal: true

require "active_job"

module Gravis
  # Starts and stops the on-demand workers. Event-driven: enqueueing a
  # gravis job triggers a run (Gravis.nudge), and each run re-arms itself
  # while work is in flight; the chain dies when there is nothing left.
  class DispatchJob < ActiveJob::Base
    queue_as :default

    # Overlapping runs would both count workers before either launches and
    # overshoot the cap. Surplus triggers are discarded; the running tick's
    # re-arm covers them.
    limits_concurrency key: "gravis_dispatch", on_conflict: :discard

    def perform
      return unless Gravis.enabled?

      @rearm = true
      tick
    rescue Gravis::ExecutorError => e
      logger.error("[gravis] executor call failed, retrying next tick: #{e.message}")
      Rails.error.report(e, handled: true, source: "gravis")
    rescue Gravis::InvalidTarget => e
      # Broken wiring: stop the chain (the next enqueue revives it) and
      # report once per process instead of every tick.
      @rearm = false
      logger.error("[gravis] #{e.message} — dispatch disabled until the target is fixed")
      unless self.class.invalid_target_reported
        self.class.invalid_target_reported = true
        Rails.error.report(e, handled: true, source: "gravis")
      end
    ensure
      rearm if @rearm
    end

    class_attribute :invalid_target_reported, default: false

    private

    def executor
      Gravis.executor
    end

    def tick
      prune_finished_ticks
      workers = executor.running
      workers -= stop_overaged(workers)
      launched = launch_deltas(workers)
      stopped = stop_idle(workers)

      @rearm = !((workers - stopped).empty? && launched.zero? &&
                 ready_by_queue.values.sum.zero? && claimed_by_queue.values.sum.zero?)
    end

    def rearm
      self.class.set(wait: Gravis.config.dispatch_interval.to_i.seconds).perform_later
    rescue => e
      logger.error("[gravis] failed to re-arm dispatch chain: #{e.class}: #{e.message}")
    end

    # The tick chain is gravis bookkeeping, not the app's work — at one tick
    # per dispatch_interval it would otherwise dominate the host app's
    # finished-jobs list in Mission Control. Each tick deletes its finished
    # predecessors; failed ticks never get finished_at, so real problems
    # stay visible.
    def prune_finished_ticks
      SolidQueue::Job.where(class_name: self.class.name).where.not(finished_at: nil).delete_all
    end

    GRAVIS_QUEUE_SQL = "LIKE '#{QUEUE_PREFIX}-%'"

    def ready_by_queue
      @ready_by_queue ||= SolidQueue::ReadyExecution
        .where("queue_name #{GRAVIS_QUEUE_SQL}")
        .group(:queue_name).count
    end

    def claimed_by_queue
      @claimed_by_queue ||= SolidQueue::ClaimedExecution
        .joins(:job)
        .where("#{SolidQueue::Job.table_name}.queue_name #{GRAVIS_QUEUE_SQL}")
        .group("#{SolidQueue::Job.table_name}.queue_name").count
    end

    # One worker works one job at a time, so aim for one worker per job in
    # flight (ready + claimed) — a waiting job never queues behind a busy
    # warm worker.
    def launch_deltas(workers)
      launched = 0
      capacity = Gravis.config.max_concurrent_tasks.to_i - workers.size

      ready_by_queue.each do |queue, ready|
        break if capacity <= 0

        size = launchable_size(queue)
        next unless size

        serving = workers.count { |w| w[:queue] == queue }
        in_flight = ready + claimed_by_queue.fetch(queue, 0)
        delta = [ in_flight - serving, capacity ].min
        next if delta <= 0

        cpu, memory = size
        delta.times { executor.launch(cpu: cpu, memory: memory, queue: queue) }
        capacity -= delta
        launched += delta
      end

      launched
    end

    def launchable_size(queue)
      size = Sizes.parse_queue(queue)
      unless size
        logger.warn("[gravis] ignoring unparseable gravis queue #{queue.inspect}")
        return nil
      end

      executor.validate_size!(cpu: size[0], memory: size[1])
      size
    rescue ArgumentError => e
      logger.warn("[gravis] ignoring queue #{queue.inspect}: #{e.message}")
      nil
    end

    # A worker that never finished anything gets the grace from its own
    # start, so a machine booted onto a drained queue isn't killed instantly.
    def stop_idle(workers)
      grace = Gravis.config.idle_grace.to_i

      workers.select do |worker|
        queue = worker[:queue]
        next false if count_for(ready_by_queue, queue).positive?
        next false if count_for(claimed_by_queue, queue).positive?

        last_finished = jobs_for(queue).maximum(:finished_at)
        idle_since = [ last_finished, worker[:started_at] ].compact.max
        next false if idle_since.nil? || idle_since > grace.seconds.ago

        executor.stop(worker[:id], reason: "gravis queue idle for #{grace}s")
        true
      end
    end

    # nil queue (unreadable override) counts against all gravis queues, so
    # such a worker is never stopped while any gravis work is in flight.
    def count_for(counts, queue)
      queue ? counts.fetch(queue, 0) : counts.values.sum
    end

    def jobs_for(queue)
      if queue
        SolidQueue::Job.where(queue_name: queue)
      else
        SolidQueue::Job.where("queue_name #{GRAVIS_QUEUE_SQL}")
      end
    end

    def stop_overaged(workers)
      lifetime = Gravis.config.max_lifetime.to_i

      workers.select { |w| w[:started_at] && w[:started_at] <= lifetime.seconds.ago }.each do |worker|
        executor.stop(worker[:id], reason: "exceeded gravis max lifetime of #{lifetime}s")
      end
    end
  end
end
