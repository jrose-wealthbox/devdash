# frozen_string_literal: true

module Devdash
  module Sources
    module Slack
      class Client
        def initialize(transport:, token:)
          @transport = transport
          @token = token
        end

        def each_user
          return enum_for(__method__) unless block_given?

          cursor = nil
          loop do
            query = { "limit" => "200" }
            query["cursor"] = cursor if cursor && !cursor.empty?
            response = @transport.get(path: "/api/users.list", query: query,
              headers: { "Authorization" => "Bearer #{@token}" })
            body = response.body
            unless body.is_a?(Hash) && body["ok"] == true
              error = body.is_a?(Hash) ? body["error"] : nil
              raise Devdash::Transports::AuthenticationError, "Slack authentication failed" if error == "invalid_auth"

              raise Devdash::Transports::ResponseError, "Slack users.list failed"
            end

            Array(body["members"]).each { |user| yield user }
            cursor = body.dig("response_metadata", "next_cursor").to_s.strip
            break if cursor.empty?
          end
        end
      end
    end
  end
end
