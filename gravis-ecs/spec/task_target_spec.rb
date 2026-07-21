# frozen_string_literal: true

RSpec.describe Gravis::TaskTarget do
  it "parses the ecs payload of GRAVIS_TARGET" do
    target = described_class.from_hash(TEST_TARGET)

    expect(target.cluster).to eq("test-cluster")
    expect(target.task_definition).to eq("test-app-production-gravis-task")
    expect(target.container).to eq("test-app")
    expect(target.subnets).to eq(%w[subnet-a subnet-b])
    expect(target.security_group).to eq("sg-1")
  end

  it "names every missing key so a bad deploy fails loudly" do
    expect {
      described_class.from_hash({ "cluster" => "c" })
    }.to raise_error(Gravis::InvalidTarget, /task_definition, container, subnets, security_group/)
  end

  it "rejects a missing payload" do
    expect {
      described_class.from_hash(nil)
    }.to raise_error(Gravis::InvalidTarget, /no ecs payload/)
  end
end
