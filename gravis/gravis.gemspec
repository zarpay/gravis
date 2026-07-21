# frozen_string_literal: true

require_relative "lib/gravis/version"

Gem::Specification.new do |spec|
  spec.name        = "gravis"
  spec.version     = Gravis::VERSION
  spec.authors     = [ "zarpay" ]
  spec.homepage    = "https://github.com/zarpay/gravis"
  spec.summary     = "On-demand execution of expensive Solid Queue jobs on ephemeral compute (core)"
  spec.description = "Provider-agnostic core of Gravis: jobs opt in with `include Gravis::Job` " \
                     "and declare their size; enqueueing one dispatches a right-sized ephemeral " \
                     "worker through a provider executor, stopped once the queues drain. " \
                     "Install an executor gem (e.g. gravis-ecs) — this core comes along as its " \
                     "dependency."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*", "LICENSE", "README.md"]
  spec.require_paths = [ "lib" ]

  spec.required_ruby_version = ">= 3.3"

  spec.add_dependency "activejob", ">= 8.0", "< 9"
  spec.add_dependency "railties", ">= 8.0", "< 9"
  # Upper bound is deliberate: gravis extends SolidQueue::QueueSelector's
  # public-but-undocumented surface (see gravis/queue_exclusion.rb).
  spec.add_dependency "solid_queue", ">= 1.4", "< 2"
end
