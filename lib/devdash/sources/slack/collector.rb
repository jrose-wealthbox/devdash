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
          users = @client.each_user.to_a
          source_updated_at = users.map { |user| user["updated"] }.compact.max
          cursor_after = source_updated_at ? Time.at(source_updated_at).utc.iso8601 : observed_at.iso8601
          observations = users.map do |user|
            Ingestion::SourceObservation.new(entity_type: "user", external_id: user.fetch("id"),
              source_updated_at: user["updated"] && Time.at(user.fetch("updated")).utc,
              observed_at: observed_at, api_version: "slack.users.list.v1",
              query_fingerprint: "users.list:limit=200", payload: user)
          end
          batch = Ingestion::Batch.new(source: SOURCE, scope_key: SCOPE_KEY, cursor_type: CURSOR_TYPE,
            cursor_before: cursor_before, cursor_after: cursor_after, observations: observations,
            coverages: [{ scope_type: "global", scope_key: SCOPE_KEY, entity_type: "user", status: "complete",
                          achieved_start_at: source_updated_at && Time.at(source_updated_at).utc,
                          achieved_end_at: observed_at }], page_count: 1, retry_count: 0)
          @writer.call(batch)
        end
      end
    end
  end
end

Devdash::Sources::Slack.register_normalizer!
