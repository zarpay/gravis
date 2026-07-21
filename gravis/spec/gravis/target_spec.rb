# frozen_string_literal: true

RSpec.describe Gravis::Target do
  describe ".from_env (the envelope)" do
    it "parses provider + payload" do
      target = with_gravis_wired({ provider: "fake", region: "x" }.to_json) { Gravis.target }

      expect(target.provider).to eq("fake")
      expect(target.config).to eq({ "region" => "x" })
    end

    it "is nil when unwired" do
      expect(Gravis.target).to be_nil
    end

    it "rejects malformed JSON" do
      with_gravis_wired("{nope") do
        expect { Gravis.target }.to raise_error(Gravis::InvalidTarget, /not valid JSON/)
      end
    end

    it "rejects non-object payloads" do
      with_gravis_wired("[1,2]") do
        expect { Gravis.target }.to raise_error(Gravis::InvalidTarget, /must be a JSON object/)
      end
    end

    it "requires the provider key" do
      with_gravis_wired({ cluster: "x" }.to_json) do
        expect { Gravis.target }.to raise_error(Gravis::InvalidTarget, /no "provider" key/)
      end
    end
  end

  describe "executor selection" do
    before { Gravis.config.executor = nil }

    it "follows the target's provider field" do
      with_gravis_wired({ provider: "fake", a: 1 }.to_json) do
        expect(Gravis.executor).to be_a(FakeExecutor)
        expect(Gravis.executor.target_config).to eq({ "a" => 1 })
      end
    end

    it "names the missing adapter gem for an unknown provider" do
      with_gravis_wired({ provider: "lambda" }.to_json) do
        expect { Gravis.executor }.to raise_error(Gravis::InvalidTarget, /add `gem "gravis-lambda"`/)
      end
    end

    it "falls back to the sole registered adapter when unwired (dev size validation)" do
      expect(Gravis.executor).to be_a(FakeExecutor)
    end
  end

  describe "Gravis.enabled? (tri-state)" do
    it "auto: follows GRAVIS_TARGET presence" do
      expect(Gravis.enabled?).to be(false)
      with_gravis_wired { expect(Gravis.enabled?).to be(true) }
    end

    it "false is a kill switch even when wired" do
      Gravis.config.enabled = false
      with_gravis_wired { expect(Gravis.enabled?).to be(false) }
    end

    it "true forces enabled" do
      Gravis.config.enabled = true
      expect(Gravis.enabled?).to be(true)
    end
  end

  describe "Gravis.announce_boot" do
    let(:log) { StringIO.new }
    let(:logger) { Logger.new(log) }

    it "announces enabled with the executor's diagnosis" do
      with_gravis_wired { Gravis.announce_boot(logger) }

      expect(log.string).to include("[gravis] enabled — provider: fake, fake: ok")
    end

    it "announces disabled when unwired" do
      Gravis.announce_boot(logger)

      expect(log.string).to include("GRAVIS_TARGET not set; gravis jobs run inline")
    end

    it "announces the kill switch" do
      Gravis.config.enabled = false
      Gravis.announce_boot(logger)

      expect(log.string).to include("disabled by config.enabled = false")
    end

    it "reports broken wiring once and does not raise (fail-safe)" do
      with_gravis_wired("{nope") do
        expect { Gravis.announce_boot(logger) }.not_to raise_error
      end

      expect(log.string).to include("dispatch disabled until the target is fixed")
    end

    it "strict mode raises on missing wiring" do
      Gravis.config.enabled = true

      expect { Gravis.announce_boot(logger) }.to raise_error(Gravis::NotConfigured)
    end

    it "strict mode raises on broken wiring" do
      Gravis.config.enabled = true

      with_gravis_wired("{nope") do
        expect { Gravis.announce_boot(logger) }.to raise_error(Gravis::InvalidTarget)
      end
    end
  end
end

RSpec.describe "contract edges" do
  it "kill switch: the dispatch still enqueues but performs as a no-op" do
    Gravis.config.enabled = false
    job = Class.new(ActiveJob::Base) { include Gravis::Job; def perform; end }
    stub_const("KilledJob", job)

    with_gravis_wired { KilledJob.perform_later }
    expect(enqueued_dispatches.size).to eq(1)

    executor = Gravis.executor
    allow(executor).to receive(:running)
    with_gravis_wired { Gravis::DispatchJob.perform_now }
    expect(executor).not_to have_received(:running)
  end

  it "boot recovery dispatches when wired work is already waiting" do
    SolidQueue::Job.create!(queue_name: "gravis-vcpu-2-mem-8", class_name: "X",
      active_job_id: SecureRandom.uuid, arguments: {})

    with_gravis_wired { Gravis.recover_pending }

    expect(enqueued_dispatches.size).to eq(1)
  end

  it "boot recovery is silent when unwired or when nothing waits" do
    Gravis.recover_pending
    with_gravis_wired { Gravis.recover_pending }

    expect(enqueued_dispatches).to be_empty
  end

  it "kill switch releases the queue exclusion even when wired" do
    SolidQueue::Job.create!(queue_name: "gravis-vcpu-2-mem-8", class_name: "X",
      active_job_id: SecureRandom.uuid, arguments: {})
    Gravis.config.enabled = false

    with_gravis_wired do
      names = SolidQueue::QueueSelector.new("*", SolidQueue::ReadyExecution)
        .scoped_relations.flat_map { |r| r.distinct.pluck(:queue_name) }
      expect(names).to include("gravis-vcpu-2-mem-8")
    end
  end

  it "strict mode passes and announces when wiring is valid" do
    Gravis.config.enabled = true
    log = StringIO.new

    with_gravis_wired { Gravis.announce_boot(Logger.new(log)) }

    expect(log.string).to include("[gravis] enabled — provider: fake")
  end

  it "config.executor override beats the target's provider" do
    override = Class.new(FakeExecutor)
    Gravis.config.executor = override

    with_gravis_wired({ provider: "ecs", a: 1 }.to_json) do
      expect(Gravis.executor).to be_a(override)
      expect(Gravis.executor.target_config).to eq({ "a" => 1 })
    end
  end

  it "resolve rejects settings that are neither names nor classes" do
    expect { Gravis::Executor.resolve(123) }
      .to raise_error(ArgumentError, /unknown executor/)
  end
end
