# Provisioning the infrastructure (ECS Fargate)

> Provider-specific: this document belongs to the [gravis-ecs](../gravis-ecs/README.md) executor.


Gravis needs exactly one thing from your infrastructure: **a task definition to launch**, and the
`GRAVIS_TARGET` env var on the always-on worker telling gravis where it is. Use any tool —
Terraform, CDK, CloudFormation, the console. The contract:

```
GRAVIS_TARGET = {
  "provider":        "ecs",                     # selects the executor gem
  "cluster":         "my-cluster",
  "task_definition": "my-app-gravis",          # family name — latest ACTIVE revision is launched
  "container":       "app",                    # container name inside the task definition
  "subnets":         ["subnet-a", "subnet-b"], # private subnets for the tasks
  "security_group":  "sg-123"
}
```

The task definition should be a **clone of your worker's**: same image, env, secrets, log
configuration, and — importantly — the **same IAM task role**, so everything you grant the worker
(S3, secrets, …) automatically applies to gravis tasks. Only three deltas:

- command: `["./bin/rails", "gravis:work"]` (gem-shipped entrypoint)
- cpu/memory: any valid baseline (e.g. 1024/2048) — every launch overrides the real size per job
- `stopTimeout: 120` — gives Solid Queue time to release claimed jobs on graceful stop

Register a new revision of it on every deploy (same pipeline as your worker's task definition) so
gravis tasks always boot the newest release.

<details>
<summary><b>Terraform recipe</b></summary>

```hcl
resource "aws_ecs_task_definition" "gravis" {
  family                   = "my-app-gravis"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024   # baseline — overridden per launch
  memory                   = 2048
  task_role_arn            = aws_iam_role.worker_task.arn      # reuse the worker's
  execution_role_arn       = aws_iam_role.worker_execution.arn # reuse the worker's

  container_definitions = jsonencode([{
    name        = "app"
    image       = var.app_image           # same image as the worker
    command     = ["./bin/rails", "gravis:work"]
    environment = var.worker_environment  # same env as the worker
    secrets     = var.worker_secrets
    stopTimeout = 120
    logConfiguration = { /* same as the worker */ }
  }])
}

# The dispatcher (worker) needs permission to manage gravis tasks:
resource "aws_iam_role_policy" "gravis_dispatch" {
  role = aws_iam_role.worker_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = "arn:aws:ecs:*:*:task-definition/my-app-gravis:*"
        Condition = { ArnEquals = { "ecs:cluster" = var.cluster_arn } }
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:StopTask", "ecs:DescribeTasks", "ecs:ListTasks", "ecs:TagResource"]
        Resource = "*"
        Condition = { ArnEquals = { "ecs:cluster" = var.cluster_arn } }
      },
      {
        # Launching a task hands it these roles — AWS requires explicit permission.
        # Forgetting this is the classic first-launch AccessDeniedException.
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [aws_iam_role.worker_task.arn, aws_iam_role.worker_execution.arn]
      }
    ]
  })
}

# Hand the target to the gem (env var on the WORKER service):
# GRAVIS_TARGET = jsonencode({ provider = "ecs", cluster = ..., task_definition = "my-app-gravis",
#                              container = "app", subnets = [...], security_group = ... })
```

</details>

<details>
<summary><b>CDK recipe</b></summary>

```ts
const gravisTaskDef = new ecs.FargateTaskDefinition(this, "GravisTaskDef", {
  family: "my-app-gravis",
  cpu: 1024, memoryLimitMiB: 2048,                       // baseline — overridden per launch
  taskRole: workerTaskDef.taskRole,                      // reuse the worker's
  executionRole: workerTaskDef.obtainExecutionRole(),
});
gravisTaskDef.addContainer("app", {
  image: sameImageAsWorker,
  command: ["./bin/rails", "gravis:work"],
  environment: sameEnvAsWorker,
  secrets: sameSecretsAsWorker,
  stopTimeout: cdk.Duration.seconds(120),
  logging: sameLoggingAsWorker,
});

// dispatch IAM (RunTask on this family + StopTask/Describe/List/Tag in cluster + PassRole
// on the two roles), then hand the target to the gem:
workerService.taskDefinition.defaultContainer!.addEnvironment("GRAVIS_TARGET",
  JSON.stringify({
    provider: "ecs",
    cluster: cluster.clusterName,
    task_definition: gravisTaskDef.family,
    container: "app",
    subnets: vpc.privateSubnets.map(s => s.subnetId),
    security_group: workerSecurityGroup.securityGroupId,   // reuse the worker's
  }));
```

</details>

You can deploy this in any order. Before it's deployed, `GRAVIS_TARGET` doesn't exist, so
gravis is off and the jobs run on your existing workers. Once deployed, your normal workers
stop picking up gravis queues and the on-demand tasks take over. Nothing to coordinate.

