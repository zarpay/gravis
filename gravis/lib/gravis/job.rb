# frozen_string_literal: true

require "active_support/concern"

module Gravis
  # Marks a job as gravis-executed:
  #
  #   class HeavyJob < ApplicationJob
  #     include Gravis::Job
  #     gravis cpu: 8, memory: 16   # vCPU, GB — optional
  #   end
  module Job
    extend ActiveSupport::Concern

    included do
      class_attribute :gravis_cpu, :gravis_memory, instance_accessor: false

      queue_as do
        Gravis.queue_for(
          self.class.gravis_cpu || Gravis.config.default_cpu,
          self.class.gravis_memory || Gravis.config.default_memory
        )
      end
    end

    class_methods do
      # Declares the worker size; validated at class-load so a bad pair
      # fails in development, not at dispatch.
      def gravis(cpu:, memory:)
        Gravis.executor.validate_size!(cpu: cpu, memory: memory)
        self.gravis_cpu = cpu
        self.gravis_memory = memory
      end
    end
  end
end
