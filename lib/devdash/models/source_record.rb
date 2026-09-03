# frozen_string_literal: true

module Devdash
  module Models
    class SourceRecord < BaseRecord
      belongs_to :collector_run

      attr_readonly :collector_run_id, :source, :scope_key, :entity_type, :external_id,
        :source_updated_at, :observed_at, :api_version, :query_fingerprint,
        :payload_hash, :payload_json

      validates :source, :scope_key, :entity_type, :external_id,
        :observed_at, :query_fingerprint, :payload_hash, :payload_json,
        presence: true

      def assign_attributes(new_attributes)
        keys = new_attributes.respond_to?(:keys) ? new_attributes.keys.map(&:to_s) : []
        if persisted? && (keys & self.class.readonly_attributes.to_a).any?
          raise ActiveRecord::ReadonlyAttributeError, "source evidence is immutable"
        end

        super
      end
    end
  end
end
