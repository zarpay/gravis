# frozen_string_literal: true

require "aws-sdk-ecs"
require "gravis/task_target"

module Gravis
  class Executor
    # ECS Fargate executor. Launches one infra-owned task definition with
    # per-call RunTask overrides: task-level cpu/memory for the job's size,
    # and GRAVIS_QUEUES so the task polls only its own size's queue.
    class Ecs < Executor
      # startedBy tag telling gravis-launched tasks apart from service tasks.
      STARTED_BY = "gravis"

      QUEUES_ENV_VAR = "GRAVIS_QUEUES"

      # Retried on the next tick. Missing credentials count as transient —
      # they often appear after boot (role attach, SSO refresh).
      RESCUED_AWS_ERRORS = [
        Aws::Errors::ServiceError,
        Aws::Errors::MissingCredentialsError,
        Aws::Errors::MissingRegionError,
        Aws::Errors::NoSuchProfileError,
        Seahorse::Client::NetworkingError
      ].freeze

      # https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html
      SIZES = {
        0.25 => [ 0.5, 1, 2 ],
        0.5  => [ 1, 2, 3, 4 ],
        1    => (2..8).to_a,
        2    => (4..16).to_a,
        4    => (8..30).to_a,
        8    => 16.step(60, 4).to_a,
        16   => 32.step(120, 8).to_a
      }.freeze

      def validate_target!
        target
      end

      def diagnosis
        "cluster: #{target.cluster}, task_definition: #{target.task_definition}"
      end

      def validate_size!(cpu:, memory:)
        allowed = SIZES[Sizes.normalize(cpu)]
        unless allowed
          raise ArgumentError,
            "gravis: #{cpu} vCPU is not a valid Fargate size (valid: #{SIZES.keys.join(', ')})"
        end
        unless allowed.include?(Sizes.normalize(memory))
          raise ArgumentError,
            "gravis: #{memory} GB is not valid for #{cpu} vCPU (valid: #{allowed.join(', ')} GB)"
        end
      end

      # desired_status RUNNING covers PENDING (booting) tasks too. The queue
      # is read back from the overrides ECS echoes in DescribeTasks.
      def running
        arns = client.list_tasks(
          cluster: target.cluster,
          started_by: STARTED_BY,
          desired_status: "RUNNING"
        ).task_arns
        return [] if arns.empty?

        client.describe_tasks(cluster: target.cluster, tasks: arns).tasks.map do |task|
          {
            id: task.task_arn,
            started_at: task.started_at || task.created_at,
            queue: queue_from_overrides(task)
          }
        end
      rescue *RESCUED_AWS_ERRORS => e
        raise ExecutorError, "#{e.class}: #{e.message}"
      end

      def launch(cpu:, memory:, queue:)
        client.run_task(
          cluster: target.cluster,
          task_definition: target.task_definition, # family name → latest ACTIVE revision
          launch_type: "FARGATE",
          started_by: STARTED_BY,
          propagate_tags: "TASK_DEFINITION",
          enable_ecs_managed_tags: true,
          overrides: {
            cpu: (cpu * 1024).round.to_s,       # vCPU → CPU units
            memory: (memory * 1024).round.to_s, # GB → MiB
            container_overrides: [
              {
                name: target.container,
                environment: [ { name: QUEUES_ENV_VAR, value: queue } ]
              }
            ]
          },
          network_configuration: {
            awsvpc_configuration: {
              subnets: target.subnets,
              security_groups: [ target.security_group ],
              assign_public_ip: "DISABLED"
            }
          }
        )
      rescue *RESCUED_AWS_ERRORS => e
        raise ExecutorError, "#{e.class}: #{e.message}"
      end

      # SIGTERM → Solid Queue's own graceful shutdown releases claimed jobs
      # back to ready within the task definition's stopTimeout.
      def stop(id, reason:)
        client.stop_task(cluster: target.cluster, task: id, reason: reason)
      rescue *RESCUED_AWS_ERRORS => e
        raise ExecutorError, "#{e.class}: #{e.message}"
      end

      def client
        @client ||= Aws::ECS::Client.new
      end

      private

      def target
        @target ||= TaskTarget.from_hash(target_config)
      end

      def queue_from_overrides(task)
        task.overrides
          &.container_overrides.to_a
          .flat_map { |c| c.environment.to_a }
          .find { |env| env.name == QUEUES_ENV_VAR }
          &.value
      end
    end
  end
end

Gravis::Executor.register(:ecs, Gravis::Executor::Ecs)
