# frozen_string_literal: true

module Devdash
  module Ingestion
    SourceObservation = Data.define(
      :entity_type,
      :external_id,
      :source_updated_at,
      :observed_at,
      :api_version,
      :query_fingerprint,
      :payload
    ) do
      SECRET_KEY = /\A(?:authorization|access_token|api_key|x-api-key)\z/i

      def initialize(**attributes)
        payload = deep_copy_and_freeze(attributes.fetch(:payload))
        reject_secrets!(payload)
        super(**attributes.merge(payload: payload))
      end

      private

      def deep_copy_and_freeze(value)
        copied = case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            result[deep_copy_and_freeze(key)] = deep_copy_and_freeze(child)
          end
        when Array
          value.map { |child| deep_copy_and_freeze(child) }
        when String
          value.dup.freeze
        else
          value
        end
        copied.freeze
      end

      def reject_secrets!(value)
        case value
        when Hash
          value.each do |key, child|
            raise ArgumentError, "payload contains a prohibited credential field" if key.to_s.match?(SECRET_KEY)

            reject_secrets!(child)
          end
        when Array
          value.each { |child| reject_secrets!(child) }
        end
      end
    end
  end
end
