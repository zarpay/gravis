# frozen_string_literal: true

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "global_id"
require "solid_queue"
require "gravis"

# Smallest possible Rails app: enough to boot the Solid Queue engine (its
# models are engine-autoloaded) without a dummy-app directory.
class TestApp < Rails::Application
  config.eager_load = false
  config.secret_key_base = "test"
  config.logger = Logger.new(nil)
  config.active_record.maintain_test_schema = false
end

ENV["DATABASE_URL"] = "sqlite3::memory:"
TestApp.initialize!

require "gravis/dispatch_job"

Rails.logger = Logger.new(nil)
ActiveJob::Base.logger = Logger.new(nil)
# :test adapter so specs can assert what got enqueued (dispatch re-arms,
# enqueue-trigger nudges) without anything actually executing.
ActiveJob::Base.queue_adapter = :test

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

# Solid Queue's own schema, straight from the gem — the same tables a host
# app's queue database has.
queue_schema = Gem.loaded_specs.fetch("solid_queue").full_gem_path +
  "/lib/generators/solid_queue/install/templates/db/queue_schema.rb"
load queue_schema

# The core is provider-blind, so core specs run against a fake executor —
# no cloud SDK anywhere in this suite. Size menu covers the shapes the
# specs use; error wording mirrors the real adapters'.
class FakeExecutor < Gravis::Executor
  SIZES = {
    0.25 => [ 0.5 ],
    2    => [ 4, 8 ],
    4    => [ 8, 30 ],
    8    => [ 16 ],
    16   => [ 120 ]
  }.freeze

  def validate_target!
    true
  end

  def diagnosis
    "fake: ok"
  end

  def validate_size!(cpu:, memory:)
    allowed = SIZES[Gravis::Sizes.normalize(cpu)]
    raise ArgumentError, "gravis: #{cpu} vCPU is not a valid size" unless allowed
    unless allowed.include?(Gravis::Sizes.normalize(memory))
      raise ArgumentError, "gravis: #{memory} GB is not valid for #{cpu} vCPU"
    end
  end

  def launch(cpu:, memory:, queue:); end

  def running
    []
  end

  def stop(id, reason:); end
end

Gravis::Executor.register(:fake, FakeExecutor)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random

  config.before do
    Gravis.reset!
    Gravis.config.executor = FakeExecutor
    Gravis::DispatchJob.invalid_target_reported = false
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    SolidQueue::Job.delete_all
    SolidQueue::ReadyExecution.delete_all
    SolidQueue::ClaimedExecution.delete_all
    SolidQueue::Process.delete_all
  end
end

# Wire gravis for a block: a real GRAVIS_TARGET envelope selecting the
# fake provider — exercises the same env-var contract production uses.
def with_gravis_wired(value = { provider: "fake" }.to_json)
  previous = ENV[Gravis::Target::ENV_VAR]
  ENV[Gravis::Target::ENV_VAR] = value
  yield
ensure
  ENV[Gravis::Target::ENV_VAR] = previous
end

def enqueued_dispatches
  ActiveJob::Base.queue_adapter.enqueued_jobs
    .select { |j| j[:job] == Gravis::DispatchJob }
end
