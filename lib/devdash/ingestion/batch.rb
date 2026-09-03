# frozen_string_literal: true

module Devdash
  module Ingestion
    Batch = Data.define(
      :source,
      :scope_key,
      :cursor_type,
      :cursor_before,
      :cursor_after,
      :observations,
      :coverages,
      :page_count,
      :retry_count
    ) do
      def initialize(**attributes)
        super(**attributes.merge(
          observations: deep_copy_and_freeze(attributes.fetch(:observations)),
          coverages: deep_copy_and_freeze(attributes.fetch(:coverages))
        ))
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
        else
          value
        end
        copied.freeze
      end
    end
  end
end
