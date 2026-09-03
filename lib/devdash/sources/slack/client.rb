# frozen_string_literal: true

module Devdash
  module Sources
    module Slack
      class Client
        attr_reader :page_count

        def initialize(transport:, token:)
          @transport = transport
          @token = token
          @page_count = 0
        end

        def each_user
          @page_count = 0
          return enum_for(__method__) unless block_given?

          cursor = nil
          loop do
            query = { "limit" => "200" }
            query["cursor"] = cursor if cursor && !cursor.empty?
            response = @transport.get(path: "/api/users.list", query: query,
              headers: { "Authorization" => "Bearer #{@token}" })
            @page_count += 1
            body = response.body
            unless body.is_a?(Hash) && body["ok"] == true
              error = body.is_a?(Hash) ? body["error"] : nil
              raise Devdash::Transports::AuthenticationError, "Slack authentication failed" if error == "invalid_auth"

              raise Devdash::Transports::ResponseError, "Slack users.list failed"
            end

            validate_members!(body["members"])
            body["members"].each { |user| yield user }
            cursor = body.dig("response_metadata", "next_cursor").to_s.strip
            break if cursor.empty?
          end
        end

        private

        def validate_members!(members)
          unless members.is_a?(Array)
            raise Devdash::Transports::ResponseError, "Slack users.list returned malformed members"
          end

          members.each_with_index do |member, index|
            next if member.is_a?(Hash) && member["id"].is_a?(String) && !member["id"].strip.empty?

            raise Devdash::Transports::ResponseError,
              "Slack users.list returned malformed members at index #{index}"
          end
        end
      end
    end
  end
end
