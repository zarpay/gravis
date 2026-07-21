# Contributing to Gravis

This document is for humans developing the gem further: how to work on it, the design rules that
must survive refactors, and the agreed roadmap with its reasoning — so decisions aren't
relitigated from scratch every time someone new touches the code.

## Development setup

Monorepo: `gravis/` (core) + `gravis-ecs/` (ECS adapter), lockstep-versioned from one shared `Gravis::VERSION`, released together. Per gem:

```bash
cd gravis        # or gravis-ecs
bundle install
bundle exec rspec       # full suite (~seconds; in-memory SQLite, no AWS, no Docker)
bundle exec rubocop     # rubocop-rails-omakase
```

No Rakefile, no dummy app. `spec/spec_helper.rb` boots a minimal inline Rails app and loads Solid
Queue's real schema from the installed gem — specs run against the same tables a host app has.
AWS is never called: dispatch specs stub `Gravis.executor`; the ECS adapter's specs use
`Aws::ECS::Client.new(stub_responses: true)`.

CI runs lint + tests on every PR (`.github/workflows/main.yml`).

## Architecture orientation

Read `CLAUDE.md` for the file-by-file map. The one-paragraph version: jobs opt in with
`include Gravis::Job` and declare a size; each size maps to an internal queue
(`gravis-vcpu-<cpu>-mem-<gb>`); enqueues trigger `Gravis::DispatchJob`, which launches/stops on-demand
workers through a provider adapter (`Gravis::Executor`, ECS Fargate today) and re-arms itself
only while work is in flight.

### Design rules (load-bearing — don't break these)

1. **The dispatch core is provider-blind.** `dispatch_job.rb`, `job.rb`, `sizes.rb`, and
   `gravis.rb` must never reference AWS (or any provider). Everything cloud-specific goes behind
   `Gravis::Executor`.
2. **Gravis reads Solid Queue, never writes it.** Lifecycle decisions come from counting
   `ReadyExecution` / `ClaimedExecution` and `jobs.finished_at`. Claiming, retries, and failure
   handling stay stock Solid Queue.
3. **Ruby never touches infrastructure identity.** No task-definition registration, no IAM, no
   network config invented at runtime — those come from the deployment (today: the
   `GRAVIS_TARGET` env var written by CDK).
4. **Fail-safe, not fail-loud.** Broken config (`InvalidTarget`) disables dispatch and reports via `Rails.error` once; transient provider errors (`ExecutorError`) are retried next tick. Jobs always wait
   safely in `ready` — gravis being broken must never lose or corrupt work.
5. **The queue names are internal.** Consumers declare sizes, never queues. Anything that leaks
   `gravis-vcpu-8-mem-16` into user-facing API is a regression.
6. **Deliberate non-features** (decided, with reasons — see README "contract" section): no
   pre-warm API (paying for guesses), no always-warm pool (that's the always-on worker gravis
   replaces), no "lite" Rails boot (jobs are app code; they need the app).

### Adding a provider (executor)

Subclass `Gravis::Executor`, implement `configured?`, `validate_size!`, `launch`, `running`,
`stop` (see `executor.rb` for the contract, `executor/ecs.rb` for the reference
implementation in `gravis-ecs/`). Ship it as its own `gravis-<provider>` gem in this monorepo,
exact-pinned to the core version. Raise `Gravis::ExecutorError` for transient failures,
`Gravis::InvalidTarget` for broken configuration. `config.executor = :<provider>` resolves
`gravis/executor/<provider>` via require. Size menus are a provider property — ship your own,
don't reuse Fargate's.

## Roadmap

In order. Items further down depend on the ones above proving out.

1. **Infra companion — DONE (2026-07).** Proven shape: a reusable construct that clones the
   worker service's task definition (same image/env/secrets/roles/SG), sets command
   `./bin/rails gravis:work`, grants dispatch IAM, and writes `GRAVIS_TARGET` including the
   `container` key. Reference recipes: docs/infrastructure.md.
2. **RunTask override smoke test — DONE (2026-07-21).** Verified against a real production
   Fargate cluster: a dispatcher-launched task ran with `{"cpu":"8192","memory":"16384"}`
   overrides and `describe-tasks` confirmed the size took effect.
3. **Migrate one real app end-to-end — DONE (2026-07-21).** A production Rails app runs its
   video-render pipeline on gravis: cold boot, warm reuse across jobs, idle stop at grace —
   all observed live. (Version now 0.3.1; rubygems publication tracked in item 7.)
4. **Layered target resolution** — designed, not implemented. `TaskTarget.resolve` merges three
   sources per field: explicit initializer values → `GRAVIS_TARGET` JSON →
   ECS-metadata self-introspection (cluster/subnets/SG/container discovered from the worker's own
   task via `ECS_CONTAINER_METADATA_URI_V4`). Goal: non-CDK users configure only
   `task_definition`; env-var deployments unchanged. `enabled?` becomes "target resolvable".
5. **Gem split — DONE (2026-07).** Monorepo: `gravis` core + `gravis-ecs` adapter, judoscale
   pattern (consumers install `gravis-ecs`; core arrives as an exact-pinned dependency).
   Lockstep versioning from the shared `Gravis::VERSION`; release workflow publishes both.
6. **Second provider candidates** (build on demand, not speculatively): Fly Machines (model fits
   exactly — see fly.io's "Rails Background Jobs with Fly Machines" post), GCP Cloud Run Jobs,
   Kubernetes Jobs.
7. **Publish on rubygems.org** — repo is public and scrubbed; GitHub `release` environment
   exists and the publish workflow is wired. Remaining: register pending trusted publishers
   for both gem names (org owner action; repo `zarpay/gravis`, workflow `release.yml`,
   environment `release`), then cut the v0.3.1 GitHub release.
   Prior art / positioning research: cookpad/barbeque, rails-lambda/lambdakiq,
   judoscale adapters.

## Releasing

Bump `gravis/lib/gravis/version.rb` (shared — both gems release in lockstep at this version),
merge, create a GitHub release tagged `vX.Y.Z`. The release workflow re-runs lint + tests for
both gems and publishes core then adapter to rubygems.org via trusted publishing.
Breaking changes: major-ish bump (pre-1.0: minor), `BREAKING CHANGE:` footer in the commit, and a
migration note in the release description.

## Commit conventions

Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`…), imperative subject ≤ 72 chars,
body explains *why*. Breaking changes get `!` and a `BREAKING CHANGE:` footer.
