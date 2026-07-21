# frozen_string_literal: true

Gravis.configure do |config|
  # Force gravis off (kill switch) or require it on (boot fails if not wired).
  # Default nil: on exactly when GRAVIS_TARGET is present.
  # config.enabled = nil

  # Task size for gravis jobs that don't declare their own with
  # `gravis cpu:, memory:` (vCPU / GB, must be a valid Fargate combination).
  # config.default_cpu = 2
  # config.default_memory = 8

  # Upper bound on simultaneously running gravis tasks (all sizes combined).
  # config.max_concurrent_tasks = 2

  # Seconds between dispatch ticks while tasks run or work waits. Launches
  # don't wait for it — enqueueing a gravis job dispatches immediately.
  # config.dispatch_interval = 30

  # Stop a task after its queue has been empty this long. Also the "stay
  # warm" window — jobs arriving within it skip the ~1-2 min cold start.
  # config.idle_grace = 10.minutes

  # Hard backstop: tasks older than this are stopped even mid-job.
  # config.max_lifetime = 2.hours
end
