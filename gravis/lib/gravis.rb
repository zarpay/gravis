# frozen_string_literal: true

require "gravis/version"
require "gravis/configuration"
require "gravis/target"
require "gravis/railtie" if defined?(Rails::Railtie)

# Runs heavy Solid Queue jobs on machines that exist only while there is
# work. Cloud specifics live in executor gems; the only infrastructure
# coupling is the GRAVIS_TARGET env var (see Gravis::Target).
module Gravis
  # Base class for all gravis errors.
  class Error < StandardError; end
  # Raised in strict mode (config.enabled = true) when the wiring is absent.
  class NotConfigured < Error; end
  # Raised when GRAVIS_TARGET is present but unusable (bad JSON, unknown
  # provider, missing keys) — an infrastructure bug, not an app bug.
  # Dispatch disables itself fail-safe until the configuration is fixed.
  class InvalidTarget < Error; end
  # Transient provider failure (capacity, throttle, API errors). The
  # dispatch chain logs it and retries next tick.
  class ExecutorError < Error; end

  # Prefix of the internal per-size queues (gravis-vcpu-<cpu>-mem-<gb>).
  QUEUE_PREFIX = "gravis"

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # Parsed GRAVIS_TARGET, nil when unwired; InvalidTarget when malformed.
    def target
      return @target if defined?(@target)

      @target = Target.from_env
    end

    # Selection order: config.executor override → the target's "provider"
    # field → the sole installed adapter (unwired dev/test size validation).
    def executor
      @executor ||=
        if config.executor
          Executor.resolve(config.executor, target_config: target&.config)
        elsif (t = target)
          Executor.resolve(t.provider, target_config: t.config)
        elsif (klass = Executor.sole_registered)
          klass.new(nil)
        else
          raise Gravis::Error,
            "gravis: no executor — install an adapter gem (e.g. gravis-ecs) or set config.executor"
        end
    end

    def enabled?
      case config.enabled
      when false then false
      when true then true
      else Target.present?
      end
    end

    # One boot log line, always. Strict mode raises on missing/broken
    # wiring; otherwise broken wiring is reported and dispatch stays off.
    def announce_boot(logger)
      if config.enabled == false
        logger.info("[gravis] disabled by config.enabled = false (kill switch); gravis jobs run inline")
        return
      end

      unless Target.present?
        raise NotConfigured, "#{Target::ENV_VAR} not set but config.enabled = true" if config.enabled == true

        logger.info("[gravis] disabled — #{Target::ENV_VAR} not set; gravis jobs run inline")
        return
      end

      executor.validate_target!
      logger.info("[gravis] enabled — provider: #{target.provider}, #{executor.diagnosis}")
    rescue Gravis::InvalidTarget => e
      raise if config.enabled == true

      logger.error("[gravis] #{e.message} — dispatch disabled until the target is fixed; gravis jobs will wait in ready")
      Rails.error.report(e, handled: true, source: "gravis")
    end

    def queue_for(cpu, memory)
      Sizes.queue_for(cpu, memory)
    end

    def gravis_queue?(queue_name)
      queue_name.to_s.start_with?("#{QUEUE_PREFIX}-")
    end

    # Enqueue-time trigger: dispatch now instead of waiting for a poll.
    # Scheduled jobs get a dispatch scheduled for when they become ready.
    # Deliberately NOT gated on enabled? — the enqueuing process (web) is
    # usually not the wired one; DispatchJob no-ops on the worker when
    # gravis is off.
    def nudge(job)
      return unless job && gravis_queue?(job.queue_name)
      return if job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued? == false

      if job.scheduled_at
        DispatchJob.set(wait_until: job.scheduled_at).perform_later
      else
        DispatchJob.perform_later
      end
    end

    # Revive a dead dispatch chain (process crash, or jobs enqueued while
    # gravis was off): if wired and gravis work is already waiting, dispatch
    # once. Called at boot; must never block it.
    def recover_pending
      return unless enabled?
      return unless defined?(SolidQueue::ReadyExecution)
      return unless SolidQueue::ReadyExecution.where("queue_name LIKE ?", "#{QUEUE_PREFIX}-%").exists?

      require "gravis/dispatch_job" # boot: Active Job may not be loaded yet
      DispatchJob.perform_later
    rescue => e
      Rails.logger&.warn("[gravis] boot recovery check skipped: #{e.class}: #{e.message}")
    end

    # Worker config the on-demand machine boots with (`rails gravis:work`).
    def worker_config_path
      File.expand_path("gravis/worker_queue.yml", __dir__)
    end

    # @api private — test hook
    def reset!
      @config = nil
      @executor = nil
      remove_instance_variable(:@target) if defined?(@target)
    end
  end
end

require "gravis/sizes"
require "gravis/executor"
require "gravis/job"
