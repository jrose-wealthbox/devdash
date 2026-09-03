# frozen_string_literal: true

require "json"
require_relative "client"
require_relative "user_normalizer"

module Devdash
  module Sources
    module Slack
      def self.register_normalizer!
        normalizer = UserNormalizer
        registered = Devdash::Normalizers::Registry.fetch(source: "slack", entity_type: "user")
        return registered if registered.equal?(normalizer)

        raise ArgumentError, "different normalizer already registered for slack:user"
      rescue KeyError
        Devdash::Normalizers::Registry.register(source: "slack", entity_type: "user", normalizer: normalizer)
      end

      class Collector
        SOURCE = "slack"
        SCOPE_KEY = "workspace"
        CURSOR_TYPE = "full_snapshot"

        def initialize(client:, writer: Devdash::Ingestion::Writer.new, clock: -> { Time.now.utc })
          Slack.register_normalizer!
          @client = client
          @writer = writer
          @clock = clock
        end

        def call
          cursor = Models::SyncCursor.find_by(source: SOURCE, scope_key: SCOPE_KEY, cursor_type: CURSOR_TYPE)
          cursor_before = cursor&.cursor_value
          observed_at = @clock.call
          batch = begin
            users = @client.each_user.to_a
            page_count = client_page_count(default: 1)
            users_with_timestamps = users.map { |user| [user, updated_at_for(user)] }
            source_updated_at = users_with_timestamps.map(&:last).max
            cursor_after = source_updated_at ? source_updated_at.iso8601 : observed_at.iso8601
            observations = users_with_timestamps.map do |user, user_updated_at|
              Ingestion::SourceObservation.new(entity_type: "user", external_id: user.fetch("id"),
                source_updated_at: user_updated_at, observed_at: observed_at,
                api_version: "slack.users.list.v1", query_fingerprint: "users.list:limit=200", payload: user)
            end
            Ingestion::Batch.new(source: SOURCE, scope_key: SCOPE_KEY, cursor_type: CURSOR_TYPE,
              cursor_before: cursor_before, cursor_after: cursor_after, observations: observations,
              coverages: [{ scope_type: "global", scope_key: SCOPE_KEY, entity_type: "user", status: "complete",
                            achieved_start_at: source_updated_at, achieved_end_at: observed_at }], page_count: page_count, retry_count: 0)
          rescue StandardError => error
            @writer.record_failure(source: SOURCE, scope_key: SCOPE_KEY, cursor_before: cursor_before,
              started_at: observed_at, error: error, page_count: client_page_count(default: 0))
            raise
          end

          @writer.call(batch)
        end

        private

        def updated_at_for(user)
          updated = user["updated"]
          return Time.at(updated).utc if updated.is_a?(Integer)

          raise ArgumentError,
            "Slack user #{user["id"] || "unknown"} has missing or non-integer updated timestamp"
        end

        def client_page_count(default:)
          return default unless @client.respond_to?(:page_count)

          count = @client.page_count
          count.is_a?(Integer) && count >= 0 ? count : default
        end
      end
    end
  end
end

Devdash::Sources::Slack.register_normalizer!
