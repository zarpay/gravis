# frozen_string_literal: true

module Gravis
  # The ECS slice of GRAVIS_TARGET. `container` names the container inside
  # the task definition so RunTask overrides can address it.
  TaskTarget = Struct.new(:cluster, :task_definition, :container, :subnets, :security_group, keyword_init: true) do
    def self.from_hash(data)
      raise InvalidTarget, "#{Target::ENV_VAR} has no ecs payload" unless data.is_a?(Hash)

      missing = %w[cluster task_definition container subnets security_group].reject { |k| data[k] }
      raise InvalidTarget, "#{Target::ENV_VAR} missing keys: #{missing.join(', ')}" if missing.any?

      new(
        cluster: data["cluster"],
        task_definition: data["task_definition"],
        container: data["container"],
        subnets: Array(data["subnets"]),
        security_group: data["security_group"]
      )
    end
  end
end
