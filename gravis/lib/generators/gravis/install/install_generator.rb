# frozen_string_literal: true

require "rails/generators"

module Gravis
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_initializer
        template "initializer.rb", "config/initializers/gravis.rb"
      end

      def show_next_steps
        say <<~STEPS

          Gravis installed. Remaining steps:

          1. Mark expensive jobs:

               class HeavyJob < ApplicationJob
                 include Gravis::Job
                 gravis cpu: 8, memory: 16   # vCPU / GB, optional
               end

          2. Scope your always-on worker to light queues (config/queue.yml):

               queues: <%= ENV.fetch("SOLID_QUEUE_QUEUES", "*") %>

          3. Provision the gravis task definition and GRAVIS_TARGET env
             var in your infrastructure (see the gravis README for recipes).
        STEPS
      end
    end
  end
end
