# frozen_string_literal: true

require "json"
require "active_record"
require_relative "../../devdash"
require_relative "../models/linear_issue"
require_relative "../models/issue_repository_link"
require_relative "../models/repository"
require_relative "../models/pull_request"
require_relative "manual_configuration"

module Devdash
  module Identity
    class IssueRepositoryResolver
      Candidate = Data.define(:repository, :evidence_kind, :evidence_reference, :priority, :confidence)

      def initialize(configuration:, repositories: nil)
        @configuration = configuration
        @repositories = repositories
      end

      def call(issue = nil, github_links: nil, linked_pull_requests: nil, primary_repository: nil, **options)
        issue ||= options[:linear_issue] || options[:issue]
        if issue.nil?
          return Models::LinearIssue.order(:id).flat_map { |item| call(item) }
        end

        github_links ||= linked_pull_requests
        candidates = []
        candidates.concat(github_candidates(github_links)) if github_links
        candidates.concat(configured_candidates(issue))
        candidates.concat(token_candidates(issue))
        candidates.concat(existing_candidates(issue))
        candidates = deduplicate_candidates(candidates)
        primary_selector = primary_repository || configured_primary(issue)
        if primary_selector
          repository = repository_for(primary_selector)
          candidates << Candidate.new(repository:, evidence_kind: "manual_primary",
            evidence_reference: "#{issue.identifier}:#{repository.full_name}", priority: 0, confidence: 1.0)
          candidates = deduplicate_candidates(candidates)
        end
        candidates << Candidate.new(repository: nil, evidence_kind: "unmapped",
          evidence_reference: issue.identifier.to_s, priority: Float::INFINITY, confidence: 0.0) if candidates.empty?

        best_priority = candidates.map(&:priority).min
        strongest = candidates.select { |candidate| candidate.priority == best_priority }
        repository_ids = strongest.map { |candidate| candidate.repository&.id }.compact.uniq
        status = if repository_ids.empty?
          "unmapped"
        elsif repository_ids.length == 1
          "resolved"
        else
          "multi-repo"
        end
        primary_id = if status == "resolved"
          repository_ids.first
        end

        persist_candidates(issue, candidates, status:, primary_id:)
      end

      def primary_repository_for(issue)
        issue = Models::LinearIssue.find(issue) unless issue.respond_to?(:issue_repository_links)
        issue.issue_repository_links.find_by(primary: true)&.repository
      end

      def links_for_scope(issue:, repository_scope:)
        links = issue.issue_repository_links.to_a
        return links if repository_scope.to_s == "all" || repository_scope == :all

        names = repository_scope.respond_to?(:repository_names) ? repository_scope.repository_names : Array(repository_scope)
        ids = Models::Repository.where(full_name: names).or(Models::Repository.where(alias_name: names)).pluck(:id)
        links.select { |link| link.primary? && ids.include?(link.repository_id) }
      end

      private

      def github_candidates(links)
        if links.is_a?(Hash)
          links = links.flat_map do |repository, references|
            Array(references).map { |reference| { repository:, reference: } }
          end
        end
        Array(links).filter_map do |link|
          repository, reference = if link.respond_to?(:repository)
            [link.repository, "github_pr:#{link.respond_to?(:number) ? link.number : link.id}"]
          elsif link.is_a?(Hash)
            repo = link[:repository] || link["repository"] || link[:repository_name] || link["repository_name"] || link[:repo] || link["repo"]
            repo = repository_for(repo) unless repo.respond_to?(:full_name)
            reference = link[:reference] || link["reference"] || link[:id] || link["id"] ||
              link[:pull_request_number] || link["pull_request_number"] || link[:number] || link["number"] || "github_pr"
            [repo, reference]
          end
          next unless repository

          Candidate.new(repository:, evidence_kind: "github_pr", evidence_reference: reference.to_s,
            priority: 1, confidence: 1.0)
        end
      end

      def configured_candidates(issue)
        mappings = @configuration.repository_mappings
        candidates = []
        project_token = issue.identifier.to_s.split("-", 2).first
        add_mapping(candidates, mappings["linear_projects"], [issue.project_name, issue.project_id, project_token], "linear_project", 2)
        add_mapping(candidates, mappings["linear_teams"], [issue.team_name, issue.team_id], "linear_team", 2)
        labels_from(issue).each do |label|
          mapping = mappings["linear_labels"] || {}
          add_mapping(candidates, mapping, [label], "linear_label", 2)
        end
        candidates
      end

      def add_mapping(candidates, mapping, values, evidence_kind, priority)
        return unless mapping.is_a?(Hash)

        values = values.compact.map { |value| value.to_s.downcase }
        mapping.each do |key, selector|
          next unless values.include?(key.to_s.downcase)

          # A project/team/label may intentionally map to more than one
          # configured repository. Keep every equally strong candidate so the
          # caller can see a multi-repo result.
          Array(selector).each_with_index do |repository_selector, index|
            candidates << Candidate.new(repository: repository_for(repository_selector), evidence_kind:, evidence_reference: "#{evidence_kind}:#{key}:#{index}",
              priority:, confidence: 0.9)
          end
          next
        end
        mapping.each do |key, selector|
          suffix = key.to_s.split(":", 2).last
          next unless values.include?(suffix.downcase) && suffix != key.to_s

          Array(selector).each_with_index do |repository_selector, index|
            candidates << Candidate.new(repository: repository_for(repository_selector), evidence_kind:, evidence_reference: "#{evidence_kind}:#{key}:#{index}",
              priority:, confidence: 0.9)
          end
        end
      end

      def token_candidates(issue)
        mappings = @configuration.repository_mappings
        enabled = mappings["enable_identifier_tokens"] || mappings["identifier_tokens_enabled"]
        return [] unless enabled == true

        text = [issue.identifier, issue.title].compact.join(" ")
        repositories.each_with_object([]) do |repository, candidates|
          token = Regexp.escape(repository.alias_name)
          next unless text.match?(%r{\[#{token}\]}i)

          candidates << Candidate.new(repository:, evidence_kind: "identifier_token",
            evidence_reference: "token:#{repository.alias_name}", priority: 3, confidence: 0.7)
        end
      end

      def existing_candidates(issue)
        issue.issue_repository_links.filter_map do |link|
          next unless link.repository

          priority = case link.evidence_kind.to_s
          when "github_pr" then 1
          when "manual_primary" then 0
          when "linear_project", "linear_team", "linear_label" then 2
          when "identifier_token" then 3
          else 4
          end
          Candidate.new(repository: link.repository, evidence_kind: link.evidence_kind,
            evidence_reference: link.evidence_reference, priority:, confidence: link.confidence || 0.5)
        end
      end

      def configured_primary(issue)
        mappings = @configuration.repository_mappings
        [mappings["primary_issues"], mappings["issue_primary"]].compact.each do |mapping|
          next unless mapping.is_a?(Hash)

          selector = mapping[issue.identifier.to_s] || mapping[issue.identifier.to_s.upcase]
          return selector if selector
        end
        nil
      end

      def persist_candidates(issue, candidates, status:, primary_id:)
        records = candidates.sort_by { |candidate| [candidate.priority, candidate.repository&.full_name.to_s,
          candidate.evidence_kind.to_s, candidate.evidence_reference.to_s] }.map do |candidate|
          link = issue.issue_repository_links.find_or_initialize_by(
            evidence_kind: candidate.evidence_kind, evidence_reference: candidate.evidence_reference
          )
          link.assign_attributes(repository: candidate.repository, confidence: candidate.confidence,
            resolution_status: status, primary: !!(primary_id && candidate.repository&.id == primary_id))
          link.save!
          link
        end
        # Existing evidence can have been retained by the schema while a
        # fresh source omitted it; its derived status is still recomputed.
        issue.issue_repository_links.where.not(id: records.map(&:id)).update_all(
          resolution_status: status, primary: false
        ) if records.any?
        records
      end

      def repositories
        @repositories || Models::Repository.where(enabled: true).order(:full_name).to_a
      end

      def repository_for(selector)
        return selector if selector.respond_to?(:full_name)

        selector = selector.to_s
        repository = repositories.find { |item| [item.alias_name, item.full_name].include?(selector) }
        raise ConfigurationError, "unknown repository selector: #{selector}" unless repository

        repository
      end

      def labels_from(issue)
        metadata = issue.metadata_json.to_s
        return [] if metadata.empty?

        payload = JSON.parse(metadata)
        labels = payload["labels"] || payload.dig("labelConnection", "nodes") || payload.dig("labels", "nodes") || []
        labels = labels["nodes"] if labels.is_a?(Hash)
        Array(labels).filter_map { |label| label.is_a?(Hash) ? (label["name"] || label["id"]) : label }
      rescue JSON::ParserError
        []
      end

      def deduplicate_candidates(candidates)
        candidates.each_with_object({}) do |candidate, unique|
          key = [candidate.evidence_kind, candidate.evidence_reference]
          existing = unique[key]
          unique[key] = candidate if existing.nil? || candidate.priority < existing.priority
        end.values
      end
    end
  end
end
