# Architecture


Two halves, one point of coupling:

| Half | Owns |
|---|---|
| `gravis` gem | job sizing, dispatch lifecycle, ECS calls |
| your infrastructure (Terraform/CDK/…) | the task definition, IAM, and the `GRAVIS_TARGET` env var |

When the env var is absent, gravis no-ops and jobs run inline — nothing breaks. That's the
normal state in development and test.

## Life of a gravis job

1. `RenderVideoJob.perform_later(video)` — the job row lands on the internal per-size queue
   (`gravis-vcpu-8-mem-16`) in your existing Solid Queue tables.
2. The enqueue triggers `Gravis::DispatchJob` on the always-on worker, in the same DB
   transaction.
3. The dispatcher calls ECS `RunTask` with a task-size override (8 vCPU / 16 GB) and
   `GRAVIS_QUEUES=gravis-vcpu-8-mem-16`. The machine boots in ~1–2 min and polls only that queue.
4. The task claims the job, works it, then the next one — warm for the rest of the burst.
5. The dispatcher re-checks every `dispatch_interval` while anything runs or waits: queue empty
   past `idle_grace` → `StopTask`; task older than `max_lifetime` → `StopTask`.
6. Everything drained and stopped → the dispatch chain dies. The next enqueue revives it.

## Internals

**Queue routing (`gravis/job.rb`, `gravis/sizes.rb`).** `include Gravis::Job` installs a
`queue_as` block resolving at enqueue time to `gravis-vcpu-<cpu>-mem-<gb>`. One internal queue per size
class is what guarantees a small task never claims a big job. The `gravis` macro validates sizes
when the class is defined.

**Wildcard exclusion (`gravis/queue_exclusion.rb`).** Gravis workers pick gravis queues; app
workers pick app queues — automatically. A module prepended into `SolidQueue::QueueSelector`
makes wildcard (`"*"`) workers stop matching `gravis-*` queues while gravis is enabled, so no
app ever scopes `SOLID_QUEUE_QUEUES` by hand and first-come claiming can't land an 8-vCPU job
on the small always-on box. Explicitly named gravis queues (the on-demand task's own config)
are untouched; with gravis disabled the exclusion is off and jobs run inline.

**Enqueue trigger (`Gravis.nudge`, wired by the Railtie).** The Railtie subscribes to Active
Job's `enqueue.active_job` / `enqueue_at.active_job` notifications. A job landing on a `gravis-*`
queue (with gravis enabled) enqueues `Gravis::DispatchJob` immediately — or scheduled for when a
`set(wait:)` job becomes ready. Bursts don't pile up dispatches:
`limits_concurrency key: "gravis_dispatch", to: 1, on_conflict: :discard` serializes ticks and
discards surplus triggers.

**The dispatch tick (`gravis/dispatch_job.rb`).** Each run:

1. `executor.running` — the executor lists live gravis workers (booting included), each tagged
   with the size queue it serves.
2. **Reap**: tasks older than `max_lifetime` are stopped, even mid-job.
3. **Launch**: per `gravis-*` queue, aim for one worker per job in flight (ready + claimed),
   bounded by the global cap — so a waiting job never queues behind a busy warm worker.
4. **Stop**: a task is stopped when *its own queue* has nothing ready, nothing claimed, and the
   newer of (last `finished_at` on that queue, task start) is older than `idle_grace`.
5. **Re-arm or die**: anything still running, launched, ready, or claimed → re-enqueue itself
   `dispatch_interval` seconds out; otherwise the chain ends. Invariant: every tick re-arms
   unless there is nothing left to do, and every enqueue wakes it — work is never stranded.

**Launching (executor gems).** The dispatch core is provider-blind — it talks only to the
`Gravis::Executor` interface (`config.executor`), and everything cloud-specific lives in an
executor gem. The reference implementation is `gravis-ecs` (RunTask with per-launch task-size
overrides and a `GRAVIS_QUEUES` env override — mechanics in
[gravis-ecs/README.md](../gravis-ecs/README.md)). Whatever the provider, Ruby never creates
infrastructure identity (templates, IAM, networks) at runtime — that stays in your
provisioning tool.

**Inside the on-demand worker.** The container command is `./bin/rails gravis:work`: a gem-shipped rake task
pointing `SOLID_QUEUE_CONFIG` at the gem-bundled worker config (`queues: ENV["GRAVIS_QUEUES"]`,
1 process × 1 thread — one big job gets the whole box) and invoking stock `solid_queue:start`.
No dispatcher/scheduler processes — the always-on box runs those. Nothing is generated into your
app for this.

**Failure paths.** AWS errors (capacity, throttle): logged with a `[gravis]` prefix,
reported through the Rails error-reporting API (`Rails.error` — delivered to whatever error tracker the host app subscribes), retried on the next tick — jobs wait safely in `ready`.
Malformed `GRAVIS_TARGET`: dispatch disables itself fail-safe (error-reported once per process, log
per attempt) and recovers automatically on the next correct deploy. Task crash (OOM, kill):
stock Solid Queue prune fails the claimed job with `ProcessPrunedError` ~5 min later — visible
in Mission Control, and a Retry there re-enqueues it, which triggers a fresh machine
automatically.

## Runtime behavior

- **Warm bursts**: jobs arriving within `idle_grace` of the last one land on the running machine
  with zero wait; only the first job of a burst pays the boot.
- **Graceful stop**: `StopTask` → SIGTERM → Solid Queue's own shutdown releases claimed jobs back
  to `ready`; the next machine re-runs them.
- **Visibility**: jobs appear in Mission Control exactly as always (claimed by the task's
  process). Task logs land wherever the task definition's log configuration points (e.g. the
  CloudWatch group cloned from your worker), one stream per task. Tasks inherit the task
  definition's cost-allocation tags (`aws ecs describe-tasks --include TAGS`).


## Cold starts

The first job of a burst pays: provider provisioning (on Fargate ~30–60 s, fixed) + pulling
your image + Rails boot — typically 1–2 min. Inherent to scale-to-zero; gravis does not pre-warm (paying for
guesses) and has no warm pool (that's the always-on worker it replaces). What softens it:

| Lever | Owner | Effect |
|---|---|---|
| `idle_grace` (default 10 min) | app config | Only the first job of a burst pays the boot; raise it to trade idle minutes for fewer cold starts |
| Image size | your Dockerfile | Fargate pulls the full image every boot — no layer cache |
| [SOCI index](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/container-considerations.html) in ECR | your CI | Task starts before the image finishes downloading; build-pipeline change only |
