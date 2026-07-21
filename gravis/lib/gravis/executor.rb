# frozen_string_literal: true

module Gravis
  # Provider seam. The core only talks to this interface; everything
  # cloud-specific lives in an executor gem (gravis-ecs, …), which
  # registers itself on require. Errors: ExecutorError = transient,
  # retried next tick; InvalidTarget = broken configuration, dispatch
  # disables itself until fixed.
  class Executor
    class << self
      def registry
        @registry ||= {}
      end

      def register(name, klass)
        registry[name.to_s] = klass
      end

      def resolve(setting, target_config: nil)
        case setting
        when Class then setting.new(target_config)
        when Symbol, String then resolve_adapter(setting.to_s, target_config)
        else
          raise ArgumentError, "gravis: unknown executor #{setting.inspect} — use a symbol (e.g. :ecs) or an executor class"
        end
      end

      # Used when neither config nor GRAVIS_TARGET picked one — with exactly
      # one adapter gem installed there is nothing to choose.
      def sole_registered
        registry.values.first if registry.size == 1
      end

      private

      def resolve_adapter(name, target_config)
        klass = registry[name] || begin
          require "gravis/executor/#{name}"
          registry[name]
        rescue LoadError
          nil
        end

        unless klass
          raise InvalidTarget,
            "gravis: executor :#{name} is not available — add `gem \"gravis-#{name.tr('_', '-')}\"` to your Gemfile"
        end

        klass.new(target_config)
      end
    end

    # The executor's slice of GRAVIS_TARGET (everything but "provider").
    attr_reader :target_config

    def initialize(target_config = nil)
      @target_config = target_config
    end

    # Shape-check the target payload; raise InvalidTarget naming what's wrong.
    def validate_target!
      raise NotImplementedError
    end

    # One short line for the boot log (e.g. "cluster: x, task_definition: y").
    def diagnosis
      ""
    end

    # Raise ArgumentError unless (cpu vCPU, memory GB) is on this provider's menu.
    def validate_size!(cpu:, memory:)
      raise NotImplementedError
    end

    def launch(cpu:, memory:, queue:)
      raise NotImplementedError
    end

    # => [{ id:, started_at:, queue: }] for every live worker, booting included.
    def running
      raise NotImplementedError
    end

    def stop(id, reason:)
      raise NotImplementedError
    end
  end
end
