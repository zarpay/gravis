# frozen_string_literal: true

module Gravis
  # Host-app tunables.
  class Configuration
    # vCPU / GB for jobs without their own `gravis cpu:, memory:`.
    attr_accessor :default_cpu, :default_memory

    # Max simultaneous workers, all sizes combined.
    attr_accessor :max_concurrent_tasks

    # Seconds between dispatch checks while work is in flight; launches
    # never wait for it (enqueues dispatch immediately).
    attr_accessor :dispatch_interval

    # Stop a worker after its queue is empty this long; also the warm window.
    attr_accessor :idle_grace

    # Workers older than this are stopped even mid-job.
    attr_accessor :max_lifetime

    # nil = auto (on when GRAVIS_TARGET present), false = kill switch,
    # true = strict (boot fails if wiring absent/broken).
    attr_accessor :enabled

    # Executor override; normally GRAVIS_TARGET's "provider" selects it.
    attr_accessor :executor

    def initialize
      @enabled = nil
      @executor = nil
      @default_cpu = 2
      @default_memory = 8
      @max_concurrent_tasks = 2
      @dispatch_interval = 30
      @idle_grace = 600
      @max_lifetime = 7200
    end
  end
end
