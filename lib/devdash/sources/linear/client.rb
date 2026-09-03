# frozen_string_literal: true

require "time"
require_relative "../../../devdash"

module Devdash
  module Sources
    module Linear
      class Client
        class RelationHydrationError < Devdash::Error
          attr_reader :issue_id

          def initialize(issue_id)
            @issue_id = issue_id
            super("Linear response missing data.issue during relation hydration for #{issue_id}")
          end
        end

        ISSUE_PAGE_SIZE = 50
        RELATION_PAGE_SIZE = 50

        ISSUE_NODE_FIELDS = <<~GRAPHQL.freeze
          id identifier title url createdAt updatedAt startedAt completedAt canceledAt archivedAt trashed estimate
          team { id name } project { id name } state { id name type }
          creator { id name email } assignee { id name email }
        GRAPHQL

        HISTORY_NODE_FIELDS = <<~GRAPHQL.freeze
          id createdAt updatedAt actor { id name email } actorId changes
          archived archivedAt autoArchived autoClosed trashed
          addedLabelIds addedLabels { id name } removedLabelIds removedLabels { id name }
          addedToReleaseIds addedToReleases { id name } removedFromReleaseIds removedFromReleases { id name }
          attachment { id title url } attachmentId
          fromState { id name } toState { id name }
          fromAssignee { id name email } toAssignee { id name email }
          fromCycle { id name } toCycle { id name }
          fromParent { id identifier title } toParent { id identifier title }
          fromDelegate { id name email } toDelegate { id name email }
          fromProjectMilestone { id name } toProjectMilestone { id name }
          fromAssigneeId toAssigneeId fromCycleId toCycleId
          fromDueDate toDueDate fromEstimate toEstimate
          fromParentId toParentId fromPriority toPriority
          fromProjectId toProjectId fromStateId toStateId fromTeamId toTeamId
          fromTitle toTitle
          fromProject { id name } toProject { id name }
          fromTeam { id name } toTeam { id name }
          fromSlaBreached fromSlaBreachesAt fromSlaStartedAt fromSlaType
          toSlaBreached toSlaBreachesAt toSlaStartedAt toSlaType updatedDescription
        GRAPHQL

        ISSUE_QUERY = <<~GRAPHQL.freeze
          query Issues($filter: IssueFilter, $after: String) {
            issues(filter: $filter, first: #{ISSUE_PAGE_SIZE}, after: $after, orderBy: updatedAt) {
              nodes { #{ISSUE_NODE_FIELDS} }
              pageInfo { hasNextPage endCursor }
            }
          }
        GRAPHQL

        ISSUE_LOOKUP_QUERY = <<~GRAPHQL.freeze
          query Issue($id: String!) {
            issue(id: $id) { #{ISSUE_NODE_FIELDS} }
          }
        GRAPHQL

        ISSUE_RELATIONS_QUERY = <<~GRAPHQL.freeze
          query IssueRelations($id: String!, $labelsAfter: String, $attachmentsAfter: String) {
            issue(id: $id) {
              labels(first: #{RELATION_PAGE_SIZE}, after: $labelsAfter, includeArchived: true) {
                nodes { id name }
                pageInfo { hasNextPage endCursor }
              }
              attachments(first: #{RELATION_PAGE_SIZE}, after: $attachmentsAfter, includeArchived: true) {
                nodes { id title url }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
        GRAPHQL

        HISTORY_QUERY = <<~GRAPHQL.freeze
          query IssueHistory($id: String!, $after: String) {
            issue(id: $id) { history(first: 100, after: $after, includeArchived: true) {
              nodes { #{HISTORY_NODE_FIELDS} }
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
          each_connection(query: ISSUE_QUERY, variables: issue_variables(updated_since), path: %w[data issues]) do |node|
            yield hydrate_issue(node)
          end
        end

        def issue(id:)
          body = post(query: ISSUE_LOOKUP_QUERY, variables: { "id" => id })
          issue = body.dig("data", "issue")
          issue && hydrate_issue(issue)
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

        def hydrate_issue(issue)
          relations = issue_relations(id: issue.fetch("id"))
          issue.merge(
            "labels" => { "nodes" => relations.fetch("labels") },
            "attachments" => { "nodes" => relations.fetch("attachments") }
          )
        end

        def issue_relations(id:)
          nodes = { "labels" => [], "attachments" => [] }
          cursors = { "labels" => nil, "attachments" => nil }
          finished = { "labels" => false, "attachments" => false }

          until finished.values.all?
            body = post(query: ISSUE_RELATIONS_QUERY, variables: {
              "id" => id, "labelsAfter" => cursors.fetch("labels"), "attachmentsAfter" => cursors.fetch("attachments")
            })
            issue = body.dig("data", "issue")
            raise RelationHydrationError, id unless issue.is_a?(Hash)

            %w[labels attachments].each do |name|
              connection = issue[name]
              raise Devdash::Error, "Linear response missing #{name} relation connection for issue #{id}" unless connection.is_a?(Hash)
              relation_nodes = connection["nodes"]
              raise Devdash::Error, "Linear response missing #{name} relation nodes for issue #{id}" unless relation_nodes.is_a?(Array)
              page = page_info!(connection)
              next if finished.fetch(name)

              nodes.fetch(name).concat(relation_nodes)
              if page["hasNextPage"]
                cursors[name] = page["endCursor"]
                raise Devdash::Error, "Linear response missing pagination cursor" if cursors[name].to_s.empty?
              else
                finished[name] = true
              end
            end
          end

          nodes
        end

        def post(query:, variables:)
          response = @http.post(path: "/graphql", headers: {
            "Authorization" => @api_key, "Content-Type" => "application/json"
          }, body: { "query" => query, "variables" => variables })
          body = response.body
          errors = body.is_a?(Hash) ? body["errors"] : nil
          if errors && !errors.empty?
            details = Array(errors).filter_map do |error|
              next unless error.is_a?(Hash)

              code = error["code"] || error.dig("extensions", "code")
              [code, error["message"]].compact.join(": ")
            end
            raise Devdash::Error, "Linear GraphQL error: #{details.join("; ")}".slice(0, 500)
          end
          body
        end

        def each_connection(query:, variables:, path:)
          cursor = nil
          loop do
            vars = variables.merge("after" => cursor)
            body = post(query:, variables: vars)
            connection = path.inject(body) { |value, key| value.is_a?(Hash) ? value[key] : nil }
            raise Devdash::Error, "Linear response missing connection" unless connection.is_a?(Hash)
            nodes = connection["nodes"]
            raise Devdash::Error, "Linear response missing connection nodes" unless nodes.is_a?(Array)
            nodes.each { |node| yield node }
            page = page_info!(connection)
            break unless page["hasNextPage"]
            cursor = page["endCursor"]
            raise Devdash::Error, "Linear response missing pagination cursor" if cursor.to_s.empty?
          end
        end

        def page_info!(connection)
          page = connection["pageInfo"]
          raise Devdash::Error, "Linear response missing pageInfo" unless page.is_a?(Hash)
          unless [true, false].include?(page["hasNextPage"])
            raise Devdash::Error, "Linear response missing pageInfo.hasNextPage"
          end

          page
        end
      end
    end
  end
end
