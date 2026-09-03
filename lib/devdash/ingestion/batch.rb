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
          observations: attributes.fetch(:observations).freeze,
          coverages: attributes.fetch(:coverages).freeze
        ))
      end
    end
  end
end
