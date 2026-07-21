# frozen_string_literal: true

RSpec.describe Gravis::Job do
  let(:sized_job) do
    stub_const("RenderVideoJob", Class.new(ActiveJob::Base) do
      include Gravis::Job
      gravis cpu: 8, memory: 16

      def perform; end
    end)
  end

  let(:default_job) do
    stub_const("EverydayExpensiveJob", Class.new(ActiveJob::Base) do
      include Gravis::Job

      def perform; end
    end)
  end

  it "routes the job to the queue for its declared size" do
    expect(sized_job.new.queue_name).to eq("gravis-vcpu-8-mem-16")
  end

  it "falls back to the configured default size" do
    expect(default_job.new.queue_name).to eq("gravis-vcpu-2-mem-8")
  end

  it "follows a changed default without redefining the class" do
    Gravis.config.default_cpu = 4
    Gravis.config.default_memory = 30

    expect(default_job.new.queue_name).to eq("gravis-vcpu-4-mem-30")
  end

  it "rejects an invalid size at class definition time" do
    expect {
      Class.new(ActiveJob::Base) do
        include Gravis::Job
        gravis cpu: 2, memory: 100
      end
    }.to raise_error(ArgumentError, /100 GB is not valid for 2 vCPU/)
  end

  describe "enqueue trigger (Gravis.nudge via Active Job notifications)" do
    it "dispatches immediately when a gravis job is enqueued and gravis is enabled" do
      with_gravis_wired { sized_job.perform_later }

      expect(enqueued_dispatches.size).to eq(1)
      expect(enqueued_dispatches.first[:at]).to be_nil
    end

    it "schedules the dispatch for when a delayed gravis job becomes ready" do
      with_gravis_wired { sized_job.set(wait: 10.minutes).perform_later }

      expect(enqueued_dispatches.size).to eq(1)
      expect(enqueued_dispatches.first[:at]).to be_within(5).of(10.minutes.from_now.to_f)
    end

    it "dispatches even from an unwired process — the worker decides whether gravis is on" do
      sized_job.perform_later

      expect(enqueued_dispatches.size).to eq(1)
    end

    it "does not dispatch for non-gravis jobs" do
      plain = stub_const("PlainJob", Class.new(ActiveJob::Base) { def perform; end })
      with_gravis_wired { plain.perform_later }

      expect(enqueued_dispatches).to be_empty
    end
  end
end
