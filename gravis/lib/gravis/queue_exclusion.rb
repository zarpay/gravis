# frozen_string_literal: true

module Gravis
  # Prepended into SolidQueue::QueueSelector. While gravis is enabled,
  # wildcard ("*") workers stop matching gravis queues, so a big job can't
  # be claimed by the small always-on worker. Workers that name gravis
  # queues explicitly (the on-demand machines) are unaffected.
  module QueueExclusion
    GRAVIS_QUEUE_MATCH = "queue_name LIKE '#{Gravis::QUEUE_PREFIX}-%'"

    def scoped_relations
      return super unless exclude_gravis_queues?

      super.map { |relation| relation.where.not(GRAVIS_QUEUE_MATCH) }
    end

    private

    def exclude_gravis_queues?
      Gravis.enabled? && raw_queues.none? { |queue| Gravis.gravis_queue?(queue) }
    end
  end
end
