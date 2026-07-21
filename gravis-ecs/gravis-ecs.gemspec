# frozen_string_literal: true

require_relative "../gravis/lib/gravis/version"

Gem::Specification.new do |spec|
  spec.name        = "gravis-ecs"
  spec.version     = Gravis::VERSION
  spec.authors     = [ "zarpay" ]
  spec.homepage    = "https://github.com/zarpay/gravis"
  spec.summary     = "ECS Fargate executor for Gravis"
  spec.description = "Runs Gravis jobs on on-demand ECS Fargate tasks: RunTask with per-job " \
                     "task-size overrides, launched while work is waiting and stopped once " \
                     "the queues drain. This is the gem apps install; the provider-agnostic " \
                     "core (gravis) comes along as a dependency."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*", "LICENSE", "README.md"]
  spec.require_paths = [ "lib" ]

  spec.required_ruby_version = ">= 3.3"

  # Exact pin — core and adapter release in lockstep from one repo; no
  # version matrix can exist (judoscale pattern).
  spec.add_dependency "gravis", Gravis::VERSION
  spec.add_dependency "aws-sdk-ecs", "~> 1"
end
