# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"
require "gravis-ecs"

# Fake AWS credentials so an accidentally-real client never probes the EC2
# metadata endpoint (slow network timeout in specs). All ECS calls are
# stubbed; these are never used for real requests.
ENV["AWS_REGION"] ||= "us-east-1"
ENV["AWS_ACCESS_KEY_ID"] ||= "test"
ENV["AWS_SECRET_ACCESS_KEY"] ||= "test"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random

  config.before { Gravis.reset! }
end

# The ecs payload of a GRAVIS_TARGET envelope (everything but "provider").
TEST_TARGET = {
  "cluster" => "test-cluster",
  "task_definition" => "test-app-production-gravis-task",
  "container" => "test-app",
  "subnets" => %w[subnet-a subnet-b],
  "security_group" => "sg-1"
}.freeze
