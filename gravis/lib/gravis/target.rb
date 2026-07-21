# frozen_string_literal: true

require "json"

module Gravis
  # The wiring contract: one env var, every provider.
  #
  #   GRAVIS_TARGET = {"provider": "ecs", ...executor-specific payload...}
  #
  # The core owns this envelope; the named executor owns the rest of the
  # payload. Absent = gravis inert; malformed = InvalidTarget.
  class Target
    ENV_VAR = "GRAVIS_TARGET"

    class << self
      def present?
        ENV[ENV_VAR].to_s.strip != ""
      end

      def from_env(raw = ENV[ENV_VAR])
        return nil if raw.to_s.strip.empty?

        data = begin
          JSON.parse(raw)
        rescue JSON::ParserError => e
          raise InvalidTarget, "#{ENV_VAR} is not valid JSON: #{e.message}"
        end
        raise InvalidTarget, "#{ENV_VAR} must be a JSON object" unless data.is_a?(Hash)

        provider = data["provider"].to_s
        raise InvalidTarget, %(#{ENV_VAR} has no "provider" key) if provider.empty?

        new(provider: provider, config: data.except("provider"))
      end
    end

    attr_reader :provider, :config

    def initialize(provider:, config:)
      @provider = provider
      @config = config
    end
  end
end
