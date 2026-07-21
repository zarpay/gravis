# frozen_string_literal: true

RSpec.describe Gravis::Executor::Ecs do
  subject(:executor) { described_class.new(TEST_TARGET) }

  let(:ecs) { Aws::ECS::Client.new(stub_responses: true) }

  before { executor.instance_variable_set(:@client, ecs) }

  describe "#validate_target!" do
    it "accepts a complete ecs payload" do
      expect { executor.validate_target! }.not_to raise_error
    end

    it "names every missing key so a bad deploy fails loudly" do
      broken = described_class.new({ "cluster" => "c" })

      expect { broken.validate_target! }
        .to raise_error(Gravis::InvalidTarget, /task_definition, container, subnets, security_group/)
    end
  end

  describe "#diagnosis" do
    it "summarizes the wiring for the boot log" do
      expect(executor.diagnosis).to eq("cluster: test-cluster, task_definition: test-app-production-gravis-task")
    end
  end

  describe "#validate_size!" do
    it "accepts valid Fargate combinations" do
      expect { executor.validate_size!(cpu: 2, memory: 8) }.not_to raise_error
      expect { executor.validate_size!(cpu: 0.25, memory: 0.5) }.not_to raise_error
      expect { executor.validate_size!(cpu: 16, memory: 120) }.not_to raise_error
    end

    it "rejects an unknown vCPU count and lists the valid ones" do
      expect { executor.validate_size!(cpu: 3, memory: 8) }
        .to raise_error(ArgumentError, /3 vCPU is not a valid Fargate size/)
    end

    it "rejects memory outside the vCPU's range and lists what fits" do
      expect { executor.validate_size!(cpu: 2, memory: 32) }
        .to raise_error(ArgumentError, /32 GB is not valid for 2 vCPU/)
    end

    it "rejects 8-vCPU memory that is not a 4 GB step" do
      expect { executor.validate_size!(cpu: 8, memory: 17) }
        .to raise_error(ArgumentError, /17 GB is not valid/)
    end
  end

  describe "#running" do
    it "returns id, start time, and served queue for tasks tagged startedBy=gravis" do
      started = Time.utc(2026, 7, 6, 12, 0, 0)
      ecs.stub_responses(:list_tasks, task_arns: %w[arn:one])
      ecs.stub_responses(:describe_tasks, tasks: [ {
        task_arn: "arn:one",
        started_at: started,
        overrides: {
          container_overrides: [ {
            name: "test-app",
            environment: [ { name: "GRAVIS_QUEUES", value: "gravis-vcpu-8-mem-16" } ]
          } ]
        }
      } ])

      expect(executor.running).to eq(
        [ { id: "arn:one", started_at: started, queue: "gravis-vcpu-8-mem-16" } ]
      )
      expect(ecs.api_requests.first[:params]).to include(
        cluster: "test-cluster", started_by: "gravis", desired_status: "RUNNING"
      )
    end

    it "returns a nil queue when the override is unreadable" do
      ecs.stub_responses(:list_tasks, task_arns: %w[arn:one])
      ecs.stub_responses(:describe_tasks, tasks: [ { task_arn: "arn:one", started_at: Time.now } ])

      expect(executor.running.first[:queue]).to be_nil
    end

    it "skips DescribeTasks entirely when nothing is running" do
      ecs.stub_responses(:list_tasks, task_arns: [])

      expect(executor.running).to eq([])
      expect(ecs.api_requests.map { |r| r[:operation_name] }).to eq([ :list_tasks ])
    end

    it "wraps AWS failures in ExecutorError for the dispatch retry path" do
      ecs.stub_responses(:list_tasks, "ServiceUnavailableException")

      expect { executor.running }.to raise_error(Gravis::ExecutorError)
    end

    it "wraps missing credentials in ExecutorError — misconfigured hosts retry instead of failing jobs" do
      broke = described_class.new(TEST_TARGET)
      client = instance_double(Aws::ECS::Client)
      allow(client).to receive(:list_tasks)
        .and_raise(Aws::Errors::MissingCredentialsError.new(nil, "unable to sign request"))
      broke.instance_variable_set(:@client, client)

      expect { broke.running }.to raise_error(Gravis::ExecutorError, /MissingCredentialsError/)
    end
  end

  describe "#launch" do
    it "runs the infra-defined task at the requested size, polling only its size queue" do
      executor.launch(cpu: 8, memory: 16, queue: "gravis-vcpu-8-mem-16")

      request = ecs.api_requests.last[:params]
      expect(request).to include(
        cluster: "test-cluster",
        task_definition: "test-app-production-gravis-task",
        launch_type: "FARGATE",
        started_by: "gravis",
        propagate_tags: "TASK_DEFINITION",
        enable_ecs_managed_tags: true
      )
      expect(request[:overrides]).to eq(
        cpu: "8192",
        memory: "16384",
        container_overrides: [ {
          name: "test-app",
          environment: [ { name: "GRAVIS_QUEUES", value: "gravis-vcpu-8-mem-16" } ]
        } ]
      )
      expect(request[:network_configuration][:awsvpc_configuration]).to eq(
        subnets: %w[subnet-a subnet-b],
        security_groups: %w[sg-1],
        assign_public_ip: "DISABLED"
      )
    end

    it "converts fractional vCPUs to CPU units" do
      executor.launch(cpu: 0.25, memory: 0.5, queue: "gravis-vcpu-0.25-mem-0.5")

      expect(ecs.api_requests.last[:params][:overrides]).to include(cpu: "256", memory: "512")
    end
  end

  describe "#stop" do
    it "stops the given task with a reason" do
      executor.stop("arn:one", reason: "gravis queue idle for 600s")

      expect(ecs.api_requests.last[:params]).to eq(
        cluster: "test-cluster", task: "arn:one", reason: "gravis queue idle for 600s"
      )
    end
  end

  describe "Gravis::Executor.resolve" do
    it "resolves :ecs (this adapter, self-registered) and custom classes" do
      expect(Gravis::Executor.resolve(:ecs, target_config: TEST_TARGET)).to be_a(described_class)
      expect(Gravis::Executor.resolve(described_class, target_config: TEST_TARGET)).to be_a(described_class)
    end

    it "names the missing adapter gem for an uninstalled executor" do
      expect { Gravis::Executor.resolve(:lambda) }
        .to raise_error(Gravis::InvalidTarget, /add `gem "gravis-lambda"`/)
    end
  end
end
