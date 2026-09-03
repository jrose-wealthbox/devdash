# frozen_string_literal: true

require "json"
require "time"
require "active_record"
require_relative "../definition"
require_relative "../result"
require_relative "../statistics"
require_relative "../../models/base_record"
require_relative "../../models/person"
require_relative "../../models/repository"
require_relative "../../models/source_identity"
require_relative "../../models/linear_issue"
require_relative "../../models/linear_issue_event"
require_relative "../../models/issue_repository_link"

module Devdash
  module Metrics
    module Linear
      module Support
        COMPLETED_WORDS = %w[complete completed done closed].freeze
        CANCELED_WORDS = %w[cancel canceled cancelled].freeze
        STARTED_WORDS = %w[started started_in_progress in_progress in-progress active doing development].freeze
        TERMINAL_WORDS = (COMPLETED_WORDS + CANCELED_WORDS).freeze

        Bucket = Data.define(:kind, :repository_name) do
          def primary?
            kind == :primary
          end

          def multi_repo?
            kind == :multi_repo
          end

          def unmapped?
            kind == :unmapped
          end
        end

        EventView = Data.define(:event, :assignment_person_id, :from_state, :to_state) do
          def occurred_at
            event.occurred_at.utc
          end

          def state?
            event.kind.to_s == "state"
          end

          def assignment?
            event.kind.to_s == "assignee"
          end
        end

        CompletionPeriod = Data.define(:occurred_at, :assignment_person_id, :event, :ordinal) do
          def synthetic?
            event.nil?
          end
        end

        StartedObservation = Data.define(:occurred_at, :assignment_person_id, :event)

        module ClassMethods
          def call(person:, window:, repository_scope:)
            new.call(person:, window:, repository_scope:)
          end
        end

        def definition
          self.class.definition
        end

        def self.extended(base)
          base.extend(ClassMethods)
        end

        def issue_rows(repository_scope)
          Models::LinearIssue.includes(issue_repository_links: :repository, events: {}).order(:id).to_a.filter_map do |issue|
            bucket = repository_bucket(issue, repository_scope)
            [issue, bucket] if bucket
          end
        end

        def repository_bucket(issue, repository_scope)
          links = issue.issue_repository_links.to_a
          in_scope = links.filter_map do |link|
            repository = link.repository
            next unless repository && repository_in_scope?(repository, repository_scope)

            [link, repository]
          end
          return Bucket.new(kind: :unmapped, repository_name: nil) if all_scope?(repository_scope) && in_scope.empty? && links.empty?
          return nil if in_scope.empty?

          primary = in_scope.select { |link, _repository| link.primary? }
          if primary.one?
            return Bucket.new(kind: :primary, repository_name: primary.first.last.full_name)
          end

          if in_scope.length > 1 || in_scope.any? { |link, _| link.resolution_status.to_s == "multi-repo" }
            return all_scope?(repository_scope) ? Bucket.new(kind: :multi_repo, repository_name: nil) : nil
          end

          # An unresolved one-repository link is not a primary attribution. It
          # remains visible in an all-repository report as unmapped, but cannot
          # be admitted to a single-repository primary figure.
          all_scope?(repository_scope) ? Bucket.new(kind: :unmapped, repository_name: nil) : nil
        end

        def repository_in_scope?(repository, repository_scope)
          return repository.enabled? if all_scope?(repository_scope)

          names = if repository_scope.respond_to?(:repository_names)
            repository_scope.repository_names
          else
            Array(repository_scope)
          end.map(&:to_s)
          repository.enabled? && names.any? { |name| [repository.full_name.to_s, repository.alias_name.to_s].include?(name) }
        end

        def all_scope?(repository_scope)
          return true if repository_scope == :all || repository_scope.to_s == "all"
          repository_scope.respond_to?(:key) && repository_scope.key.to_s == "all"
        end

        def person_id_for(person)
          person.respond_to?(:id) ? person.id : Integer(person)
        rescue ArgumentError, TypeError
          raise ArgumentError, "person must be a Person or person ID"
        end

        def result(definition:, person_id:, window:, repository_scope:, value:, sample_count:, breakdown:)
          Metrics::Result.new(definition:, person_id:, window:, repository_scope:, value:, sample_count:, breakdown:, coverage: nil)
        end

        def count_breakdown(rows, issue_ids:, extra: {})
          repository_values = Hash.new(0)
          multi_repo = 0
          unmapped = 0
          rows.each do |_issue, bucket, _observation|
            case bucket.kind
            when :primary then repository_values[bucket.repository_name] += 1
            when :multi_repo then multi_repo += 1
            when :unmapped then unmapped += 1
            end
          end
          {
            repository_values: repository_values.sort.to_h,
            multi_repo:,
            unmapped:,
            distinct_issues: issue_ids.uniq.length,
            issue_ids: issue_ids.uniq.sort
          }.merge(extra)
        end

        def duration_breakdown(rows, excluded: {}, extra: {})
          samples = rows.map { |_issue, _bucket, observation| observation[:hours] }.sort
          repository_samples = Hash.new { |hash, key| hash[key] = [] }
          multi_samples = []
          unmapped_samples = []
          rows.each do |_issue, bucket, observation|
            case bucket.kind
            when :primary then repository_samples[bucket.repository_name] << observation[:hours]
            when :multi_repo then multi_samples << observation[:hours]
            when :unmapped then unmapped_samples << observation[:hours]
            end
          end
          repository_values = repository_samples.transform_values { |values| Metrics::Statistics.quantile(values, 0.5) }.sort.to_h
          {
            samples: samples,
            p75: Metrics::Statistics.quantile(samples, 0.75),
            repository_values: repository_values,
            multi_repo: multi_samples.length,
            unmapped: unmapped_samples.length,
            multi_repo_value: Metrics::Statistics.quantile(multi_samples, 0.5),
            unmapped_value: Metrics::Statistics.quantile(unmapped_samples, 0.5),
            excluded: excluded,
            issue_ids: rows.map(&:first).map(&:linear_id).uniq.sort
          }.merge(extra)
        end

        def duration_result(definition:, person_id:, window:, repository_scope:, rows:, excluded: {}, extra: {})
          samples = rows.map { |_issue, _bucket, observation| observation[:hours] }
          result(definition:, person_id:, window:, repository_scope:, value: Metrics::Statistics.quantile(samples, 0.5),
            sample_count: samples.length, breakdown: duration_breakdown(rows, excluded:, extra:))
        end

        def count_result(definition:, person_id:, window:, repository_scope:, rows:, extra: {})
          result(definition:, person_id:, window:, repository_scope:, value: rows.length, sample_count: rows.length,
            breakdown: count_breakdown(rows, issue_ids: rows.map(&:first).map(&:linear_id), extra:))
        end

        def event_views(issue)
          events = issue.events.to_a.sort_by { |event| [event.occurred_at.to_f, event.stable_external_id.to_s, event.id.to_i] }
          assignment_events = events.select { |event| event.kind.to_s == "assignee" }
          current_assignee = if assignment_events.empty?
            issue.assignee_person_id
          else
            assignee_value_to_person_id(assignment_value(assignment_events.first, :from))
          end
          current_state = nil
          events.map do |event|
            from_state = nil
            to_state = nil
            if event.kind.to_s == "state"
              from_state = state_kind(event, :from)
              to_state = state_kind(event, :to)
              from_state ||= current_state
              current_state = to_state || current_state
            end
            view = EventView.new(event:, assignment_person_id: current_assignee, from_state:, to_state:)
            if event.kind.to_s == "assignee"
              current_assignee = assignee_value_to_person_id(assignment_value(event, :to))
            end
            view
          end
        end

        def completion_periods(issue)
          views = event_views(issue)
          periods = []
          current_state = nil
          views.each do |view|
            next unless view.state?

            from_state = view.from_state || current_state
            to_state = view.to_state
            if to_state == :completed && from_state != :completed
              periods << CompletionPeriod.new(occurred_at: view.occurred_at, assignment_person_id: view.assignment_person_id,
                event: view.event, ordinal: periods.length + 1)
            end
            current_state = to_state || current_state
          end
          return periods unless periods.empty?

          completed_at = source_time(issue.completed_at_source || issue[:completed_at_source])
          return [] unless completed_at && issue.state_type.to_s.downcase == "completed"

          [CompletionPeriod.new(occurred_at: completed_at, assignment_person_id: assignment_at(issue, completed_at, views),
            event: nil, ordinal: 1)]
        end

        def reopened_periods(issue)
          views = event_views(issue)
          current_state = nil
          views.filter_map do |view|
            next unless view.state?

            from_state = view.from_state || current_state
            to_state = view.to_state
            result = if from_state == :completed && to_state == :nonterminal
              CompletionPeriod.new(occurred_at: view.occurred_at, assignment_person_id: view.assignment_person_id,
                event: view.event, ordinal: 1)
            end
            current_state = to_state || current_state
            result
          end
        end

        def first_started(issue)
          views = event_views(issue)
          event_observation = views.filter_map do |view|
            next unless view.state? && view.to_state == :started

            StartedObservation.new(occurred_at: view.occurred_at, assignment_person_id: view.assignment_person_id, event: view.event)
          end.min_by { |observation| [observation.occurred_at.to_f, observation.event.stable_external_id.to_s] }
          typed = source_time(issue.started_at_source || issue[:started_at_source])
          return event_observation if event_observation && (!typed || event_observation.occurred_at <= typed)
          return StartedObservation.new(occurred_at: typed, assignment_person_id: assignment_at(issue, typed, views), event: nil) if typed

          event_observation
        end

        def assignment_at(issue, timestamp, views = event_views(issue))
          assignment_events = views.select(&:assignment?)
          return issue.assignee_person_id if assignment_events.empty?

          first = assignment_events.first
          current = assignee_value_to_person_id(assignment_value(first.event, :from))
          assignment_events.each do |view|
            break if view.occurred_at > timestamp

            current = assignee_value_to_person_id(assignment_value(view.event, :to))
          end
          current
        end

        def active_cycle_hours(issue, completion)
          started = first_started(issue)
          return [nil, false] unless started&.occurred_at
          elapsed = completion.occurred_at - started.occurred_at
          return [nil, false] if elapsed.negative?

          pauses = pause_intervals(issue, started.occurred_at, completion.occurred_at)
          views = event_views(issue)
          has_unresolved_non_started = views.any? do |view|
            view.state? && view.occurred_at >= started.occurred_at && view.occurred_at <= completion.occurred_at &&
              view.to_state == :nonterminal && !views.any? { |candidate| candidate.state? && candidate.to_state == :started && candidate.occurred_at > view.occurred_at && candidate.occurred_at <= completion.occurred_at }
          end
          approximated = started.event.nil? || has_unresolved_non_started
          [((elapsed - pauses.sum { |from, to| to - from }) / 3600.0), approximated]
        end

        def pause_intervals(issue, started_at, completed_at)
          views = event_views(issue)
          pause_started = nil
          intervals = []
          views.each do |view|
            next unless view.state? && view.occurred_at >= started_at && view.occurred_at <= completed_at

            if view.to_state == :nonterminal && pause_started.nil?
              pause_started = view.occurred_at
            elsif view.to_state == :started && pause_started
              intervals << [pause_started, view.occurred_at]
              pause_started = nil
            end
          end
          intervals
        end

        def source_time(value)
          return nil if value.nil?
          value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc
        rescue ArgumentError
          nil
        end

        def assignment_value(event, side)
          metadata = parse_metadata(event.metadata_json)
          keys = side == :from ? %w[fromAssigneeId fromAssignee from_assignee_id from_assignee] : %w[toAssigneeId toAssignee to_assignee_id to_assignee]
          value = keys.lazy.map { |key| metadata[key] }.find { |candidate| !candidate.nil? }
          value = value["id"] if value.is_a?(Hash)
          value.nil? ? (side == :from ? event.from_value : event.to_value) : value
        end

        def state_kind(event, side)
          metadata = parse_metadata(event.metadata_json)
          keys = side == :from ? %w[fromState from_state fromStateType from_state_type] : %w[toState to_state toStateType to_state_type]
          value = keys.lazy.map { |key| metadata[key] }.find { |candidate| !candidate.nil? }
          value = value["type"] || value["name"] if value.is_a?(Hash)
          value = event.from_value if value.nil? && side == :from
          value = event.to_value if value.nil? && side == :to
          normalize_state(value)
        end

        def normalize_state(value)
          text = value.to_s.strip.downcase.tr(" ", "_")
          return nil if text.empty?
          return :canceled if CANCELED_WORDS.any? { |word| text.include?(word) }
          return :completed if COMPLETED_WORDS.any? { |word| text == word || text.include?(word) }
          return :started if STARTED_WORDS.include?(text) || text.include?("in_progress") || text.include?("in-progress")
          return :nonterminal if !TERMINAL_WORDS.any? { |word| text.include?(word) }

          nil
        end

        def assignee_value_to_person_id(value)
          return nil if value.nil? || value.to_s.strip.empty?
          value = value.to_s
          identity = Models::SourceIdentity.find_by(source: "linear", external_id: value)
          return identity.person_id if identity

          Models::Person.where("LOWER(display_name) = ?", value.downcase).pick(:id)
        end

        def parse_metadata(value)
          parsed = JSON.parse(value.to_s)
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError, TypeError
          {}
        end
      end
    end
  end
end
