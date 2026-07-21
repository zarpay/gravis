# frozen_string_literal: true

RSpec.describe Gravis::Sizes do
  describe ".queue_for" do
    it "derives the internal size queue name" do
      expect(described_class.queue_for(2, 8)).to eq("gravis-vcpu-2-mem-8")
      expect(described_class.queue_for(8, 16)).to eq("gravis-vcpu-8-mem-16")
      expect(described_class.queue_for(0.25, 0.5)).to eq("gravis-vcpu-0.25-mem-0.5")
    end
  end

  describe ".parse_queue" do
    it "round-trips queue_for" do
      expect(described_class.parse_queue("gravis-vcpu-2-mem-8")).to eq([ 2, 8 ])
      expect(described_class.parse_queue("gravis-vcpu-8-mem-16")).to eq([ 8, 16 ])
      expect(described_class.parse_queue("gravis-vcpu-0.25-mem-0.5")).to eq([ 0.25, 0.5 ])
    end

    it "returns nil for non-size queue names" do
      expect(described_class.parse_queue("default")).to be_nil
      expect(described_class.parse_queue("gravis-weird")).to be_nil
    end

    it "parses syntax only — launchability is the executor's call" do
      expect(described_class.parse_queue("gravis-vcpu-3-mem-8")).to eq([ 3, 8 ])
    end
  end
end
