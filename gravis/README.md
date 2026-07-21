# gravis (core)

The shared core of [Gravis](../README.md). **Don't install this gem directly** — install the
gem for your platform (e.g. [`gravis-ecs`](../gravis-ecs/README.md)) and this one comes with it.

## What lives here

- `Gravis::Job` — the module your jobs include, and the `gravis cpu:, memory:` size setting
- `Gravis::DispatchJob` — decides when to start and stop machines
- `Gravis::Executor` — the interface a platform gem implements (`validate_target!`,
  `validate_size!`, `launch`, `running`, `stop`). Note: `Gravis::Executor` interface also
  defines two error types: `ExecutorError` (temporary problem, retried) and `InvalidTarget`
  (broken setup, gravis turns itself off and reports it)
- The piece that keeps your normal workers away from gravis queues, the `rails gravis:work`
  task the machines run, and the install generator

This gem never depends on a cloud SDK. How to write a new platform gem:
[CONTRIBUTING.md](../CONTRIBUTING.md).
