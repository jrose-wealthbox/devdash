# frozen_string_literal: true

require "active_record"
require_relative "../result"
require_relative "../definition"
require_relative "../statistics"
require_relative "../../models/base_record"
require_relative "../../models/person"
require_relative "../../models/repository"
require_relative "../../models/pull_request"
require_relative "../../models/pull_request_event"
require_relative "../../models/pull_request_review"
require_relative "../../models/pull_request_file"
require_relative "../../models/commit"
require_relative "../../models/commit_file"

module Devdash
  module Metrics
    module Github
      module Support
        module_function

        def repository_names(scope)
          names = if scope.respond_to?(:repository_names)
            Array(scope.repository_names)
          elsif scope.to_s == "all" || scope.nil?
            []
          else
            Array(scope)
          end.map { |name| name.to_s.strip }.reject(&:empty?).uniq

          relation = Models::Repository.where(enabled: true)
          return relation.order(:full_name).pluck(:full_name) if names.empty?

          relation.where(full_name: names).or(relation.where(alias_name: names)).order(:full_name).pluck(:full_name)
        end

        def repositories(scope)
          names = repository_names(scope)
          Models::Repository.where(enabled: true, full_name: names).order(:full_name).to_a
        end

        def person_id(person)
          person.respond_to?(:id) ? person.id : person
        end

        def review_person_eligible?(person_id)
          person = Models::Person.find_by(id: person_id)
          person && person.human? && !person.bot? && !person.merged_into_id &&
            !person.source_identities.where(source: "github", resolution_method: %w[unresolved provisional]).exists?
        end

        def definition(**attributes)
          Metrics::Definition.new(**attributes)
        end

        def count_result(definition:, person:, window:, repository_scope:, values:, sample_count: nil, breakdown: {})
          values = values.transform_keys(&:to_s)
          total = values.values.sum { |value| value.to_f }
          Result.new(
            definition:, person_id: person_id(person), window:, repository_scope:,
            value: total.to_i == total ? total.to_i : total,
            sample_count: sample_count || total.to_i,
            breakdown: {
              repositories: values,
              repository_values: values
            }.merge(breakdown), coverage: nil
          )
        end

        def duration_result(definition:, person:, window:, repository_scope:, samples_by_repository:, breakdown: {})
          samples_by_repository = samples_by_repository.transform_keys(&:to_s)
          all_samples = samples_by_repository.values.flatten.map(&:to_f).sort
          value = Statistics.quantile(all_samples, 0.5)
          per_repository = samples_by_repository.transform_values do |samples|
            Statistics.quantile(samples, 0.5)
          end
          Result.new(
            definition:, person_id: person_id(person), window:, repository_scope:,
            value:, sample_count: all_samples.length,
            breakdown: {
              repositories: per_repository,
              repository_values: per_repository,
              samples: all_samples,
              repository_samples: samples_by_repository
            }.merge(breakdown), coverage: nil
          )
        end

        def numeric(value)
          value.to_i
        end

        def submitted_review_rows(window, repository)
          Models::PullRequestReview.joins(:pull_request)
            .where(pull_requests: { repository_id: repository.id })
            .where("pull_request_reviews.submitted_at >= ? AND pull_request_reviews.submitted_at < ?", window.start_at, window.end_at)
            .where.not(submitted_at: nil)
            .where(state: %w[APPROVED COMMENTED CHANGES_REQUESTED approved commented changes_requested])
            .to_a
        end

        def review_diagnostics(window:, repository:, owner_id:)
          submitted_review_rows(window, repository).each_with_object(Hash.new(0)) do |review, counts|
            if review.reviewer_id.nil?
              counts[:unresolved_reviewers] += 1
            elsif !review_person_eligible?(review.reviewer_id)
              counts[:bot_or_unresolved_reviewers] += 1
            elsif review.pull_request.author_id == owner_id
              counts[:self_reviews] += 1
            end
          end
        end
      end
    end
  end
end
