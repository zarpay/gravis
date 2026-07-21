# frozen_string_literal: true

namespace :gravis do
  desc "Run Solid Queue workers polling only gravis queues (entrypoint for on-demand tasks)"
  task :work do
    ENV["SOLID_QUEUE_CONFIG"] ||= Gravis.worker_config_path
    Rake::Task["solid_queue:start"].invoke
  end
end
