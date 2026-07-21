# frozen_string_literal: true

module Gravis
  # Size ↔ queue-name mapping. Whether a pair is launchable is the
  # executor's call.
  module Sizes
    QUEUE_PATTERN = /\A#{Gravis::QUEUE_PREFIX}-vcpu-(\d+(?:\.\d+)?)-mem-(\d+(?:\.\d+)?)\z/

    class << self
      def queue_for(cpu, memory)
        "#{Gravis::QUEUE_PREFIX}-vcpu-#{format_number(cpu)}-mem-#{format_number(memory)}"
      end

      # => [cpu, memory], or nil for names that aren't gravis size queues.
      def parse_queue(queue_name)
        match = QUEUE_PATTERN.match(queue_name.to_s)
        return nil unless match

        [ normalize(match[1].to_f), normalize(match[2].to_f) ]
      end

      def normalize(value)
        value == value.to_i ? value.to_i : value.to_f
      end

      private

      def format_number(value)
        normalize(value).to_s
      end
    end
  end
end
