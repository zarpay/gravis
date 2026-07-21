# frozen_string_literal: true

RSpec.describe Gravis::DispatchJob do
  let(:executor) { Gravis.executor }

  # Job.create! readies itself via SolidQueue's after_create; a finished_at
  # marks it done (ready execution removed) for idle-grace scenarios.
  def enqueue_gravis(queue: "gravis-vcpu-2-mem-8", finished_at: nil)
    SolidQueue::Job.create!(
      queue_name: queue, class_name: "ExpensiveJob",
      active_job_id: SecureRandom.uuid, arguments: {}
    ).tap do |job|
      if finished_at
        job.ready_execution&.destroy!
        job.update!(finished_at: finished_at)
      end
    end
  end

  def claim(job)
    process = SolidQueue::Process.create!(
      kind: "Worker", name: "worker-#{SecureRandom.hex(2)}", pid: 1,
      hostname: "test", last_heartbeat_at: Time.current, metadata: {}
    )
    job.ready_execution&.destroy!
    SolidQueue::ClaimedExecution.create!(job: job, process: process)
  end

  def worker(id: "arn:task/one", started_at: 1.minute.ago, queue: "gravis-vcpu-2-mem-8")
    { id: id, started_at: started_at, queue: queue }
  end

  context "when the executor is not configured (dev/test, unwired deploys)" do
    it "does nothing and does not chain" do
      expect(executor).not_to receive(:running)

      described_class.perform_now
      expect(enqueued_dispatches).to be_empty
    end
  end

  context "when the executor's configuration is broken (infra bug)" do
    it "logs, stays quiet, and lets the chain die until the next enqueue" do
      allow(executor).to receive(:running).and_raise(Gravis::InvalidTarget, "missing keys")

      with_gravis_wired do
        expect { described_class.perform_now }.not_to raise_error
      end
      expect(enqueued_dispatches).to be_empty
    end
  end

  it "serializes overlapping ticks and discards surplus triggers" do
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.concurrency_on_conflict).to eq(:discard)
  end

  context "when enabled" do
    around { |example| with_gravis_wired { example.run } }

    before do
      allow(executor).to receive_messages(running: [], launch: nil, stop: nil)
    end

    describe "launching" do
      it "does nothing when the queues are empty and no tasks run" do
        described_class.perform_now

        expect(executor).not_to have_received(:launch)
        expect(executor).not_to have_received(:stop)
      end

      it "launches one task at the queue's size for one ready job" do
        enqueue_gravis(queue: "gravis-vcpu-2-mem-8")

        described_class.perform_now
        expect(executor).to have_received(:launch)
          .once.with(cpu: 2, memory: 8, queue: "gravis-vcpu-2-mem-8")
      end

      it "launches per size queue with each queue's own size" do
        enqueue_gravis(queue: "gravis-vcpu-2-mem-8")
        enqueue_gravis(queue: "gravis-vcpu-8-mem-16")

        described_class.perform_now
        expect(executor).to have_received(:launch).with(cpu: 2, memory: 8, queue: "gravis-vcpu-2-mem-8")
        expect(executor).to have_received(:launch).with(cpu: 8, memory: 16, queue: "gravis-vcpu-8-mem-16")
      end

      it "caps launches at max_concurrent_tasks across all sizes" do
        3.times { enqueue_gravis(queue: "gravis-vcpu-2-mem-8") }
        3.times { enqueue_gravis(queue: "gravis-vcpu-8-mem-16") }

        described_class.perform_now
        expect(executor).to have_received(:launch).twice
      end

      it "launches only the delta when a task already serves the queue" do
        5.times { enqueue_gravis(queue: "gravis-vcpu-2-mem-8") }
        allow(executor).to receive(:running).and_return([ worker(queue: "gravis-vcpu-2-mem-8") ])

        described_class.perform_now
        expect(executor).to have_received(:launch).once
      end

      it "ignores unparseable gravis queues instead of launching blind" do
        enqueue_gravis(queue: "gravis-weird")

        described_class.perform_now
        expect(executor).not_to have_received(:launch)
      end
    end

    describe "stopping idle tasks" do
      it "stops a task once its queue has been idle past the grace period" do
        enqueue_gravis(finished_at: 11.minutes.ago)
        allow(executor).to receive(:running).and_return([ worker(started_at: 20.minutes.ago) ])

        described_class.perform_now
        expect(executor).to have_received(:stop)
          .with("arn:task/one", reason: /idle for 600s/)
      end

      it "keeps a task alive within the grace period after the last finished job" do
        enqueue_gravis(finished_at: 2.minutes.ago)
        allow(executor).to receive(:running).and_return([ worker(started_at: 20.minutes.ago) ])

        described_class.perform_now
        expect(executor).not_to have_received(:stop)
      end

      it "gives a freshly booted task its grace even when the queue is already empty" do
        allow(executor).to receive(:running).and_return([ worker(started_at: 1.minute.ago) ])

        described_class.perform_now
        expect(executor).not_to have_received(:stop)
      end

      it "does not stop a task that is still working a claimed job on its queue" do
        claim(enqueue_gravis)
        allow(executor).to receive(:running).and_return([ worker(started_at: 30.minutes.ago) ])

        described_class.perform_now
        expect(executor).not_to have_received(:stop)
      end

      it "judges each task against its own queue, not other sizes' activity" do
        claim(enqueue_gravis(queue: "gravis-vcpu-8-mem-16"))
        enqueue_gravis(queue: "gravis-vcpu-2-mem-8", finished_at: 11.minutes.ago)
        allow(executor).to receive(:running).and_return([
          worker(id: "arn:task/small", started_at: 20.minutes.ago, queue: "gravis-vcpu-2-mem-8"),
          worker(id: "arn:task/big", started_at: 20.minutes.ago, queue: "gravis-vcpu-8-mem-16")
        ])

        described_class.perform_now
        expect(executor).to have_received(:stop).once
          .with("arn:task/small", reason: /idle for 600s/)
      end

      it "never stops a task with an unreadable queue while any gravis work is in flight" do
        claim(enqueue_gravis(queue: "gravis-vcpu-8-mem-16"))
        allow(executor).to receive(:running).and_return([
          worker(started_at: 30.minutes.ago, queue: nil)
        ])

        described_class.perform_now
        expect(executor).not_to have_received(:stop)
      end

      it "honors a custom idle grace" do
        Gravis.config.idle_grace = 60
        enqueue_gravis(finished_at: 2.minutes.ago)
        allow(executor).to receive(:running).and_return([ worker(started_at: 20.minutes.ago) ])

        described_class.perform_now
        expect(executor).to have_received(:stop).with("arn:task/one", reason: /idle for 60s/)
      end
    end

    describe "max-lifetime backstop" do
      it "stops an overaged task even while it holds a claimed job" do
        claim(enqueue_gravis)
        allow(executor).to receive(:running).and_return([ worker(started_at: 3.hours.ago) ])

        described_class.perform_now
        expect(executor).to have_received(:stop)
          .with("arn:task/one", reason: /max lifetime/)
      end

      it "does not double-launch to replace a task it just stopped when nothing is ready" do
        allow(executor).to receive(:running).and_return([ worker(started_at: 3.hours.ago) ])

        described_class.perform_now
        expect(executor).to have_received(:stop).once
        expect(executor).not_to have_received(:launch)
      end
    end

    describe "pruning its own history" do
      def tick_row(finished_at: nil)
        SolidQueue::Job.create!(
          queue_name: "default", class_name: "Gravis::DispatchJob",
          active_job_id: SecureRandom.uuid, arguments: {}
        ).tap do |job|
          if finished_at
            job.ready_execution&.destroy!
            job.update!(finished_at: finished_at)
          end
        end
      end

      it "deletes finished ticks so the chain leaves no trace in Mission Control" do
        2.times { tick_row(finished_at: 1.minute.ago) }

        described_class.perform_now
        expect(SolidQueue::Job.where(class_name: "Gravis::DispatchJob")).to be_empty
      end

      it "leaves unfinished ticks (failed or pending) visible" do
        tick_row

        described_class.perform_now
        expect(SolidQueue::Job.where(class_name: "Gravis::DispatchJob").count).to eq(1)
      end

      it "never touches the app's own finished jobs" do
        enqueue_gravis(finished_at: 1.minute.ago)

        described_class.perform_now
        expect(SolidQueue::Job.where(class_name: "ExpensiveJob").count).to eq(1)
      end
    end

    describe "the self-re-arming chain" do
      it "re-arms while work is waiting" do
        enqueue_gravis

        described_class.perform_now
        expect(enqueued_dispatches.size).to eq(1)
        expect(enqueued_dispatches.first[:at]).to be_present
      end

      it "re-arms while a task is still running" do
        allow(executor).to receive(:running).and_return([ worker ])

        described_class.perform_now
        expect(enqueued_dispatches.size).to eq(1)
      end

      it "re-arms while a claimed job is in flight" do
        claim(enqueue_gravis)

        described_class.perform_now
        expect(enqueued_dispatches.size).to eq(1)
      end

      it "lets the chain die once everything is drained and stopped" do
        enqueue_gravis(finished_at: 11.minutes.ago)
        allow(executor).to receive(:running).and_return([ worker(started_at: 20.minutes.ago) ])

        described_class.perform_now
        expect(executor).to have_received(:stop)
        expect(enqueued_dispatches).to be_empty
      end

      it "re-arms after a transient executor failure so the work is retried" do
        enqueue_gravis
        allow(executor).to receive(:launch)
          .and_raise(Gravis::ExecutorError, "capacity unavailable")

        expect { described_class.perform_now }.not_to raise_error
        expect(enqueued_dispatches.size).to eq(1)
      end

      it "honors a custom dispatch interval" do
        Gravis.config.dispatch_interval = 5
        enqueue_gravis

        described_class.perform_now
        expect(enqueued_dispatches.last[:at]).to be_within(2).of(5.seconds.from_now.to_f)
      end
    end
  end
end

RSpec.describe Gravis::DispatchJob, "scale-out past busy workers" do
  let(:executor) { Gravis.executor }

  def enqueue_gravis(queue: "gravis-vcpu-2-mem-8", finished_at: nil)
    SolidQueue::Job.create!(
      queue_name: queue, class_name: "ExpensiveJob",
      active_job_id: SecureRandom.uuid, arguments: {}
    ).tap do |job|
      if finished_at
        job.ready_execution&.destroy!
        job.update!(finished_at: finished_at)
      end
    end
  end

  def claim(job)
    process = SolidQueue::Process.create!(
      kind: "Worker", name: "worker-#{SecureRandom.hex(2)}", pid: 1,
      hostname: "test", last_heartbeat_at: Time.current, metadata: {}
    )
    job.ready_execution&.destroy!
    SolidQueue::ClaimedExecution.create!(job: job, process: process)
  end

  around { |example| with_gravis_wired { example.run } }
  before { allow(executor).to receive_messages(running: [], launch: nil, stop: nil) }

  it "launches a second worker when one is busy and a job waits (no queueing behind warm machines)" do
    claim(enqueue_gravis)   # busy worker's job
    enqueue_gravis          # second user's job, waiting
    allow(executor).to receive(:running).and_return([ { id: "arn:busy", started_at: 1.minute.ago, queue: "gravis-vcpu-2-mem-8" } ])

    described_class.perform_now

    expect(executor).to have_received(:launch).once.with(cpu: 2, memory: 8, queue: "gravis-vcpu-2-mem-8")
  end

  it "does not launch for claimed work already being served" do
    claim(enqueue_gravis)
    allow(executor).to receive(:running).and_return([ { id: "arn:busy", started_at: 1.minute.ago, queue: "gravis-vcpu-2-mem-8" } ])

    described_class.perform_now

    expect(executor).not_to have_received(:launch)
  end

  it "still respects the global cap" do
    claim(enqueue_gravis)
    2.times { enqueue_gravis }
    allow(executor).to receive(:running).and_return([ { id: "arn:busy", started_at: 1.minute.ago, queue: "gravis-vcpu-2-mem-8" } ])

    described_class.perform_now

    expect(executor).to have_received(:launch).once  # cap 2, one already running
  end
end
