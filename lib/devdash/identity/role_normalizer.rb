# frozen_string_literal: true

require "active_record"
require_relative "../../devdash"
require_relative "../models/person"
require_relative "../models/role_assignment"
require_relative "manual_configuration"

module Devdash
  module Identity
    class RoleNormalizer
      Classification = Data.define(:role, :level, :rule_id)
      UNKNOWN = Classification.new(role: "unknown", level: "unknown", rule_id: "unknown").freeze

      LEVEL_PATTERNS = [
        ["principal", /\bprincipal\b/i], ["staff", /\bstaff\b/i],
        ["senior", /\bsr\.?\b|\bsenior\b/i], ["lead", /\blead\b/i],
        ["junior", /\bjr\.?\b|\bjunior\b/i], ["mid", /\bmid(?:-level)?\b/i],
        ["associate", /\bassociate\b/i]
      ].freeze

      def initialize(configuration: nil, role_rules: nil, builtins: true, clock: -> { Time.now.utc })
        @configuration = configuration
        @role_rules = Array(role_rules || configuration&.role_rules).freeze
        @builtins = builtins
        @clock = clock
      end

      def call(person = nil, title: nil, source: "slack", effective_from: nil, observed_at: nil,
               role_assignment: nil, **options)
        if person && person.respond_to?(:person) && person.respond_to?(:original_title)
          role_assignment ||= person
          person = nil
        end
        person ||= options[:person]
        if role_assignment
          person ||= role_assignment.person
          title ||= role_assignment.original_title
          effective_from ||= role_assignment.effective_from
          observed_at ||= role_assignment.observed_at
        end
        raise ArgumentError, "person is required" unless person

        observed_at ||= @clock.call
        effective_from ||= observed_at
        classification = classify(person:, title:)
        persist(person, title.to_s, source:, effective_from:, observed_at:, classification:)
        classification
      end

      def classify(person: nil, title: nil)
        override = person && manual_override_for(person)
        if override && (override.role || override.level)
          return Classification.new(role: override.role || "unknown", level: override.level || "unknown",
            rule_id: "manual:#{override.key}")
        end

        title = title.to_s
        @role_rules.each do |rule|
          regexp = rule[:pattern] || rule["pattern"]
          next unless regexp && regexp.match?(title)

          return Classification.new(role: (rule[:role] || rule["role"]).to_s,
            level: (rule[:level] || rule["level"]).to_s,
            rule_id: (rule[:id] || rule["id"] || "configured").to_s)
        end
        return UNKNOWN unless @builtins

        builtin_classification(title)
      end

      private

      def persist(person, title, source:, effective_from:, observed_at:, classification:)
        assignments = person.role_assignments.where(source:).to_a
        current = assignments.select { |assignment| assignment.effective_from <= effective_from &&
          (assignment.effective_until.nil? || assignment.effective_until > effective_from) }
          .max_by { |assignment| [assignment.effective_from, assignment.id] }
        successor = assignments.select { |assignment| assignment.effective_from > effective_from }
          .min_by { |assignment| [assignment.effective_from, assignment.id] }
        if current && current.normalized_role.to_s == classification.role && current.normalized_level.to_s == classification.level
          return current
        end

        current&.update!(effective_until: effective_from) if current && current.effective_from < effective_from &&
          (current.effective_until.nil? || current.effective_until > effective_from)
        if current && current.effective_from == effective_from
          current.update!(original_title: title, normalized_role: classification.role,
            normalized_level: classification.level, observed_at:)
          return current
        end

        person.role_assignments.create!(source:, original_title: title, normalized_role: classification.role,
          normalized_level: classification.level, effective_from:, effective_until: successor&.effective_from, observed_at:)
      end

      def builtin_classification(title)
        normalized = title.to_s.strip
        return UNKNOWN if normalized.empty?
        return UNKNOWN if normalized.match?(/\b(manager|management|director|vp|vice president|head of)\b/i)
        return UNKNOWN if normalized.match?(/\b(product|design|designer|marketing|sales|recruit|intern|contractor|consultant)\b/i)
        return UNKNOWN unless normalized.match?(/\b(?:software|full[ .-]?stack|rails|ruby|backend|back[- ]end|front[- ]end|web|application|devops|platform)\b.*\b(?:engineer|developer|programmer)\b/i) ||
          normalized.match?(/\b(?:engineer|developer|programmer)\b.*\b(?:software|full[ .-]?stack|rails|ruby|backend|front[- ]end|web|application|devops|platform)\b/i)

        level = LEVEL_PATTERNS.find { |_name, regexp| regexp.match?(normalized) }&.first || "unknown"
        Classification.new(role: "software_engineer", level:, rule_id: "builtin:software-engineer")
      end

      def manual_override_for(person)
        return unless @configuration

        key = @configuration.people.keys.find do |candidate|
          candidate.casecmp?(person.display_name.to_s) ||
            (person.owner? && candidate == @configuration.owner)
        end
        key && @configuration.people[key]
      end
    end
  end
end
