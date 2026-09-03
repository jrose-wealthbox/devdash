# frozen_string_literal: true

require "time"

module Devdash
  module Sources
    module Linear
      class Client
        ISSUE_QUERY = <<~GRAPHQL.freeze
          query Issues($filter: IssueFilter, $after: String) {
            issues(filter: $filter, first: 100, after: $after) {
              nodes { id identifier title url createdAt updatedAt startedAt completedAt canceledAt estimate
                active team { id name } project { id name } state { id name type }
                creator { id name email } assignee { id name email }
                labels { nodes { id name } } attachments { nodes { id title url } }
                history { nodes { id type createdAt actor { id name email } fromState { id name type } toState { id name type } fromAssignee { id name email } toAssignee { id name email } } pageInfo { hasNextPage endCursor } }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        GRAPHQL

        HISTORY_QUERY = <<~GRAPHQL.freeze
          query IssueHistory($id: String!, $after: String) {
            issue(id: $id) { history(first: 100, after: $after) {
              nodes { id type createdAt actor { id name email } fromState { id name type } toState { id name type } fromAssignee { id name email } toAssignee { id name email } }
              pageInfo { hasNextPage endCursor }
            } }
          }
        GRAPHQL

        def initialize(http:, api_key: ENV["LINEAR_API_KEY"])
          @http = http
          @api_key = api_key.to_s
          raise Devdash::ConfigurationError, "LINEAR_API_KEY is required" if @api_key.empty?
        end

        def each_issue(updated_since: nil)
          each_connection(query: ISSUE_QUERY, variables: issue_variables(updated_since), path: %w[data issues]) { |node| yield node }
        end

        def issue(id:)
          issue = nil
          each_connection(query: ISSUE_QUERY, variables: { "filter" => { "id" => { "eq" => id } }, "after" => nil }, path: %w[data issues]) { |node| issue = node }
          issue
        end

        def issue_history(id:)
          nodes = []
          each_connection(query: HISTORY_QUERY, variables: { "id" => id, "after" => nil }, path: %w[data issue history]) { |node| nodes << node }
          nodes
        end

        private

        def issue_variables(updated_since)
          filter = updated_since ? { "updatedAt" => { "gte" => updated_since.iso8601 } } : nil
          { "filter" => filter, "after" => nil }
        end

        def each_connection(query:, variables:, path:)
          cursor = nil
          loop do
            vars = variables.merge("after" => cursor)
            response = @http.post(path: "/graphql", headers: { "Authorization" => @api_key, "Content-Type" => "application/json" }, body: { "query" => query, "variables" => vars })
            body = response.body
            errors = body.is_a?(Hash) ? body["errors"] : nil
            if errors && !errors.empty?
              details = Array(errors).filter_map { |error| error.is_a?(Hash) ? [error["code"], error["message"]].compact.join(": ") : nil }
              raise Devdash::Error, "Linear GraphQL error: #{details.join("; ")}".slice(0, 500)
            end
            connection = path.inject(body) { |value, key| value.is_a?(Hash) ? value[key] : nil }
            raise Devdash::Error, "Linear response missing connection" unless connection.is_a?(Hash)
            Array(connection["nodes"]).each { |node| yield node }
            page = connection.fetch("pageInfo", {})
            break unless page["hasNextPage"]
            cursor = page["endCursor"]
            raise Devdash::Error, "Linear response missing pagination cursor" if cursor.to_s.empty?
          end
        end
      end
    end
  end
end
