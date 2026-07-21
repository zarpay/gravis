# gravis-ecs

Runs [Gravis](../README.md) jobs on AWS ECS Fargate. This is the gem you install; the core
(`gravis`) comes with it.

```ruby
gem "gravis-ecs"
```

## What it does

When a gravis job is enqueued, this gem starts a Fargate task at the size the job asked for,
and stops it when the queue is empty:

- One task definition covers all sizes — each launch sets its own cpu/memory.
- A task only takes jobs of its own size. A small task never picks up a big job.
- Tasks are tagged so you can find them (`startedBy=gravis`) and cost-track them.
- If AWS says no (no capacity, throttled, bad credentials), gravis logs it and tries again on
  the next check. Jobs wait safely in the queue; nothing is lost.

## Requirements

1. **An always-on Solid Queue process** — a worker service, or Rails 8's Puma plugin. This is
   where gravis watches the queue from.
2. **AWS credentials** where that process runs (task role, instance profile, env keys — the
   normal SDK ways), with the permissions listed in
   [docs/infrastructure.md](../docs/infrastructure.md).
3. **The Fargate tasks can reach your queue database.** If your database isn't reachable from
   AWS, gravis-ecs won't work for you.
4. **Your app's Docker image** contains whatever the jobs need (ffmpeg, etc.) — the tasks run
   that image as-is.

## Wiring

One env var on your always-on worker, written by your infrastructure tool (Terraform, CDK, the
console):

```
GRAVIS_TARGET = {
  "provider":        "ecs",
  "cluster":         "my-cluster",
  "task_definition": "my-app-gravis",          # family name
  "container":       "app",                    # container name in the task definition
  "subnets":         ["subnet-a", "subnet-b"],
  "security_group":  "sg-123"
}
```

If the env var is missing, gravis stays off and the jobs run on your normal workers. If it's
wrong, gravis stays off, logs why, and jobs wait in the queue until you fix it.

The task definition is a copy of your worker's (same image, env, secrets, IAM roles, log
config) with three changes:

- command: `["./bin/rails", "gravis:work"]`
- any small cpu/memory (each launch overrides it)
- `stopTimeout: 120`

Copy-paste Terraform and CDK recipes, plus the IAM the worker needs:
[docs/infrastructure.md](../docs/infrastructure.md).

## Fargate size menu

`gravis cpu:, memory:` must be a pair Fargate supports. Checked when the class loads.

| vCPU | Valid memory (GB) |
|---|---|
| 0.25 | 0.5, 1, 2 |
| 0.5 | 1–4 |
| 1 | 2–8 |
| 2 | 4–16 |
| 4 | 8–30 |
| 8 | 16–60 (steps of 4) |
| 16 | 32–120 (steps of 8) |

## Troubleshooting

| Problem | Check |
|---|---|
| `AccessDeniedException` at first launch | Almost always missing `iam:PassRole` on the task definition's roles |
| `[gravis] GRAVIS_TARGET is not valid JSON / missing keys` in logs | The env var doesn't match the block above; fix and redeploy |
| Where are the task logs? | Wherever your task definition's log config points — same place as your worker's |
| What did a task cost? | `aws ecs describe-tasks --include TAGS` — tasks carry your cost tags |
