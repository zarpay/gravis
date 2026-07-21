# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Gravis runs expensive Solid Queue jobs on ephemeral compute that exists only while there is work. **Monorepo of two lockstep-versioned gems** (judoscale pattern — consumers install only the adapter): `gravis/` = provider-agnostic core (no cloud SDKs); `gravis-ecs/` = ECS Fargate executor, depends on core with an exact version pin (shared `Gravis::VERSION`). Repo root holds README, docs/, LICENSE, workflows.

## Commands

Each gem is its own bundle (CI runs a matrix over both):

```bash
cd gravis        # or gravis-ecs
bundle install
bundle exec rspec                               # that gem's tests
bundle exec rspec spec/gravis/dispatch_job_spec.rb:42     # one example
bundle exec rubocop                             # lint (rubocop-rails-omakase)
```

Core specs run against a `FakeExecutor` (`gravis/spec/spec_helper.rb`) — no AWS SDK loads in
the core suite; enable gravis in a core spec with the `with_gravis_wired` helper. The ECS
adapter's specs (`gravis-ecs/spec/`) stub `Aws::ECS::Client` and use `with_task_target`.

There is no Rakefile. CI runs rubocop + rspec on every PR.

## Architecture

Gravis has two halves with exactly one point of coupling:

- **This repo (Rails half)**: `gravis` core (mixin, dispatch lifecycle, entrypoint, generator) + `gravis-ecs` adapter (ECS calls, target parsing).
- **Infra half**: whatever provisions the on-demand worker template and writes the wiring env var — Terraform/CDK recipes live in `docs/infrastructure.md`. The recommended shape: clone the worker service's template (same image, env, secrets, security group, IAM roles — so grants to the worker automatically cover gravis workers), swap the command to `rails gravis:work`, grant dispatch IAM. Organizations typically wrap this in their own reusable construct/module.

The coupling is the `GRAVIS_TARGET` env var — JSON with `cluster`, `task_definition`, `container`, `subnets`, `security_group`, written by the provisioning tool and parsed by `Gravis::TaskTarget.from_env`. When absent, `Gravis.enabled?` is false and everything no-ops: gravis jobs run inline on whatever worker polls the queue. This is the normal state in development and test.

Jobs opt in with `include Gravis::Job` and optionally `gravis cpu:, memory:` (vCPU/GB). Each size maps to an internal queue (`gravis-vcpu-8-mem-16`) so a task launched at one size never claims another size's job. Dispatch is event-driven, not cron: enqueueing a gravis job triggers `DispatchJob` (Railtie subscribes to `enqueue.active_job`/`enqueue_at.active_job` → `Gravis.nudge`), and each run re-arms itself every `dispatch_interval` while tasks run or work waits, dying when quiescent. No `recurring.yml` involvement.

Responsibility split — core (`gravis/lib/gravis/`):

- `job.rb` — the `Gravis::Job` mixin: derives the per-size queue via `queue_as` block, validates sizes at class-load (via the executor's size menu).
- `sizes.rb` — provider-agnostic size↔queue-name mapping (`queue_for`/`parse_queue`, syntax only — launchability is the executor's call).
- `executor.rb` — the provider seam. `Gravis::Executor` defines the interface (`configured?`, `validate_size!`, `launch`, `running`, `stop`) and error contract: `Gravis::ExecutorError` = transient, retried next tick; `Gravis::InvalidTarget` = broken config, fail-safe disable. The dispatch core has zero AWS references. `config.executor = :ecs` (default) or any executor class — future providers (Fly, Cloud Run, K8s) plug in as adapter gems without touching core.
- adapter gem (`gravis-ecs/lib/gravis/`): `executor/ecs.rb` + `task_target.rb`. The ECS Fargate adapter: Fargate's cpu/memory menu, RunTask / ListTasks / StopTask, zero decisions. Tasks are identified by ECS `started_by: "gravis"`. Each RunTask carries a task-level cpu/memory override plus a `GRAVIS_QUEUES` container env override; `running` reads the queue back from the overrides echoed by DescribeTasks. Wraps `Aws::Errors::ServiceError` into `ExecutorError`.
- `dispatch_job.rb` — **all lifecycle decisions**, provider-blind (talks only to `Gravis.executor`). Per size queue: launches workers (global `max_concurrent_tasks` cap), stops them after that queue is idle past `idle_grace`, kills workers older than `max_lifetime`, then re-arms or lets the chain die. Ticks are serialized with `limits_concurrency on_conflict: :discard` so surplus triggers are dropped, not queued.
- `configuration.rb` — host-app tunables (`default_cpu`, `default_memory`, `max_concurrent_tasks`, `dispatch_interval`, `idle_grace`, `max_lifetime`). Deliberate design: all behavior is configured in Ruby; the only infrastructure input is the one env var.
- `queue_exclusion.rb` — prepended into `SolidQueue::QueueSelector` (railtie `to_prepare`): while gravis is enabled, wildcard (`"*"`) workers stop matching `gravis-*` queues, so apps never scope `SOLID_QUEUE_QUEUES` by hand; explicit gravis queue names (the on-demand task's config) are untouched. Note `"*"` normally short-circuits to `relation.all` — the patch overrides both `all?` and `all_queues`.
- `worker_queue.yml` + `tasks/gravis.rake` — the on-demand task's entrypoint is `rails gravis:work`, which points `SOLID_QUEUE_CONFIG` at the gem-bundled worker config (polls `ENV["GRAVIS_QUEUES"]`); nothing is generated into the host app for this.
- `generators/gravis/install/` — `rails generate gravis:install`, creates only the optional initializer.

Solid Queue stays the queue of record — gravis reads `SolidQueue::ReadyExecution` / `ClaimedExecution` counts to make decisions but never claims or mutates jobs. Crash recovery is stock Solid Queue (prune → `ProcessPrunedError` → manual retry in Mission Control).

Deliberate non-features (decided, don't re-propose): no pre-warm API (paying for guesses — a page view could boot a machine for nothing) and no always-warm pool (that's the always-on worker gravis replaces). Cold start is the accepted price of scale-to-zero; the only softeners are `idle_grace` (app config) and image size / SOCI (app's Dockerfile and CI — out of gravis's scope). See "The contract" section in the README.

## Testing setup

Core (`gravis/spec/`): a minimal inline Rails app (no dummy-app directory) against in-memory SQLite, loading Solid Queue's real `queue_schema.rb` — specs run against the same tables a host app has. Executor is a `FakeExecutor`; enable gravis with `with_gravis_wired`; assert re-arms/nudges via `enqueued_dispatches` (`:test` Active Job adapter). Adapter (`gravis-ecs/spec/`): no Rails boot; `Aws::ECS::Client.new(stub_responses: true)` + `with_task_target` env helper.

## Releasing

Bump `gravis/lib/gravis/version.rb` (shared by both gems — lockstep), merge, create a GitHub release tagged `vX.Y.Z`. The release workflow re-runs lint + tests for both gems, then publishes core and adapter (core first; the adapter pins it exactly).
