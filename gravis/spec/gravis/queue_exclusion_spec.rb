# frozen_string_literal: true

RSpec.describe Gravis::QueueExclusion do
  def ready(queue)
    SolidQueue::Job.create!(
      queue_name: queue, class_name: "AnyJob",
      active_job_id: SecureRandom.uuid, arguments: {}
    )
  end

  def claimable(queues)
    SolidQueue::QueueSelector.new(queues, SolidQueue::ReadyExecution)
      .scoped_relations
      .flat_map { |relation| relation.distinct.pluck(:queue_name) }
      .sort
  end

  before do
    ready("default")
    ready("heavy")
    ready("gravis-vcpu-8-mem-16")
  end

  context "when gravis is wired (production)" do
    around { |example| with_gravis_wired { example.run } }

    it "excludes gravis queues from wildcard workers — no manual SOLID_QUEUE_QUEUES scoping" do
      expect(claimable("*")).to eq(%w[default heavy])
    end

    it "leaves explicitly named gravis queues alone (the on-demand task's own config)" do
      expect(claimable("gravis-vcpu-8-mem-16")).to eq(%w[gravis-vcpu-8-mem-16])
      expect(claimable("gravis-*")).to eq(%w[gravis-vcpu-8-mem-16])
    end

    it "does not touch explicit app queue lists" do
      expect(claimable(%w[default heavy])).to eq(%w[default heavy])
    end
  end

  context "when gravis is not wired (development, test)" do
    it "wildcard workers claim everything — gravis jobs run inline" do
      expect(claimable("*")).to eq(%w[default gravis-vcpu-8-mem-16 heavy])
    end
  end
end
