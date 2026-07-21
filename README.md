# Gravis

[![CI](https://github.com/zarpay/gravis/actions/workflows/main.yml/badge.svg)](https://github.com/zarpay/gravis/actions/workflows/main.yml)
[![Ruby](https://img.shields.io/badge/ruby-%E2%89%A5%203.3-CC342D.svg)](https://www.ruby-lang.org/)
[![Rails](https://img.shields.io/badge/rails-%E2%89%A5%208.0-CC0000.svg)](https://rubyonrails.org/)

Runs your heavy Solid Queue jobs on machines that exist only while there is work.

Some jobs need a big machine (video rendering, ffmpeg, ML) but run only a few times a day.
Keeping a big worker running 24/7 for them is wasted money. With gravis, enqueueing such a job
starts a machine of the right size, and the machine is stopped when the queue is empty. Between
jobs you pay nothing.

```ruby
class RenderVideoJob < ApplicationJob
  include Gravis::Job
  gravis cpu: 8, memory: 16   # vCPU / GB

  def perform(video)
    # your code, unchanged
  end
end

RenderVideoJob.perform_later(video)   # enqueue as always
```

Everything else stays normal: jobs live in Solid Queue, show up in Mission Control, retry as
usual. The machine runs your app's own Docker image.

**When to use it:** heavy jobs where nobody waits on the result — renders, transcodes, batch
work. The first job of a burst waits 1–2 minutes for the machine to start.
**When not to:** anything a user is waiting on. Keep those on your normal worker.

## Prerequisites

- Rails 8+ with Solid Queue
- Your app deployed as a Docker image
- One always-on Solid Queue process (a worker service, or Rails 8's Puma plugin)
- An account with a supported provider — currently AWS ECS Fargate via
  [`gravis-ecs`](gravis-ecs/README.md)

## Install

**1. Add the gem for your provider:**

```ruby
gem "gravis-ecs"
```

> Not on rubygems.org yet — until then install from git:
>
> ```ruby
> gem "gravis",     github: "zarpay/gravis", glob: "gravis/*.gemspec"
> gem "gravis-ecs", github: "zarpay/gravis", glob: "gravis-ecs/*.gemspec"
> ```

**2. Mark your heavy jobs:**

```ruby
class RenderVideoJob < ApplicationJob
  include Gravis::Job
  gravis cpu: 8, memory: 16   # optional — default is 2 vCPU / 8 GB
end
```

Don't set `queue_as` on these jobs — gravis routes them itself. Your other jobs, workers, and
`queue.yml` need no changes.

**3. Set up the AWS side** — one task definition and one env var. Copy-paste recipes for
Terraform and CDK: [gravis-ecs setup](gravis-ecs/README.md#wiring) and
[docs/infrastructure.md](docs/infrastructure.md).

That's it. In development and test nothing is set up, so gravis stays off and these jobs run
inline like any other job.

## Usage

**Sizes** are vCPU / GB pairs. Invalid pairs fail when the class loads, so you find out in
development, not in production. Valid pairs for Fargate:
[size table](gravis-ecs/README.md#fargate-size-menu).

**Scheduled jobs** work: `RenderVideoJob.set(wait: 2.hours).perform_later(video)` — the machine
starts when the job is due, not before.

**Every boot logs one line** telling you where gravis stands:

```
[gravis] enabled — provider: ecs, cluster: myapp-production, task_definition: myapp-gravis
[gravis] disabled — GRAVIS_TARGET not set; gravis jobs run inline
```

## Configuration

Optional — `bin/rails generate gravis:install` writes this file with everything commented out:

| Option | Default | What it does |
|---|---|---|
| `default_cpu` / `default_memory` | `2` / `8` | Size for jobs that don't declare one |
| `max_concurrent_tasks` | `2` | Max machines at once — your cost ceiling |
| `dispatch_interval` | `30` | Seconds between checks while work is running |
| `idle_grace` | `600` | Stop a machine after its queue is empty this long |
| `max_lifetime` | `7200` | Kill any machine older than this, even mid-job |
| `enabled` | `nil` | `false` = force off; `true` = fail boot if not set up; `nil` = on when wired |
| `executor` | `nil` | Only for custom providers |

## Troubleshooting

| Problem | Check |
|---|---|
| Jobs sit in "queued" | Boot log says enabled? `[gravis]` errors in the worker log? Is the always-on worker running? |
| `AccessDeniedException` at first launch | Missing `iam:PassRole` — see [docs/infrastructure.md](docs/infrastructure.md) |
| Machine never stops | A running job keeps it alive (on purpose). Otherwise wait out `idle_grace` |
| Machine killed mid-job | It hit `max_lifetime`. The job retries or shows as failed in Mission Control |
| Invalid size error at boot | The cpu/memory pair isn't valid on Fargate — see the size table |

## More

- How it works inside: [docs/architecture.md](docs/architecture.md)
- AWS setup recipes: [docs/infrastructure.md](docs/infrastructure.md)
- Developing the gem, writing a new provider: [CONTRIBUTING.md](CONTRIBUTING.md)

## License

[MIT](LICENSE)
