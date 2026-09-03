# frozen_string_literal: true

require "yaml"
require "pathname"

module Devdash
  module Identity
    class ManualConfiguration
      SUPPORTED_SOURCES = %w[github slack linear calendar google_calendar outlook_calendar].freeze
      PersonOverride = Data.define(:key, :identities, :role, :level, :exclude_from_cohort, :primary_repository)

      attr_reader :owner, :people, :role_rules, :repository_mappings, :path

      def self.load(path:, repository_aliases: nil, repository_names: nil, repository_selectors: nil,
                    allowed_sources: SUPPORTED_SOURCES)
        raw = YAML.safe_load_file(path.to_s, permitted_classes: [], aliases: false)
        new(raw:, path:, repository_aliases:, repository_names:, repository_selectors:, allowed_sources:)
      rescue Errno::ENOENT => error
        raise Devdash::ConfigurationError, "identity configuration not found: #{error.message}"
      rescue Psych::Exception => error
        raise Devdash::ConfigurationError, "invalid identity YAML: #{error.message}"
      end

      def initialize(raw:, path: nil, repository_aliases: nil, repository_names: nil, repository_selectors: nil,
                     allowed_sources: SUPPORTED_SOURCES)
        @path = path && Pathname(path)
        @repository_aliases = Array(repository_aliases).map(&:to_s)
        @repository_names = Array(repository_names).map(&:to_s)
        @repository_selectors = Array(repository_selectors || @repository_aliases + @repository_names).map(&:to_s).uniq.freeze
        @allowed_sources = Array(allowed_sources).map(&:to_s).map(&:downcase).freeze
        validate_root!(raw)

        @owner = raw.fetch("owner").to_s.strip
        people_data = raw.fetch("people")
        @people = people_data.each_with_object({}) do |(key, value), result|
          key = key.to_s
          raise Devdash::ConfigurationError, "person keys must not be blank" if key.empty?
          validate_person!(key, value)
          identities = normalize_identities(value["identities"] || {}, person_key: key)
          primary_repository = optional_string(value["primary_repository"])
          repository_for(primary_repository) if primary_repository
          result[key] = PersonOverride.new(
            key:, identities: identities.freeze,
            role: optional_string(value["role"]), level: optional_string(value["level"]),
            exclude_from_cohort: value.fetch("exclude_from_cohort", false),
            primary_repository:
          )
        end.freeze
        raise Devdash::ConfigurationError, "owner must name a configured person" unless @people.key?(@owner)

        @role_rules = normalize_role_rules(raw.fetch("role_rules", []))
        @repository_mappings = deep_freeze(deep_copy(raw.fetch("repository_mappings", {})))
        validate_repository_mappings!
        validate_primary_mapping_conflicts!
      end

      def person(key)
        people.fetch(key.to_s)
      end

      def owner_override
        person(owner)
      end

      def identity_owner(source:, external_id:)
        target = people.values.find { |override| override.identities[source.to_s.downcase] == external_id.to_s }
        target&.key
      end

      def repository_for(selector)
        selector = selector.to_s
        return selector if @repository_selectors.empty? || @repository_selectors.include?(selector)

        raise Devdash::ConfigurationError, "unknown repository selector: #{selector}"
      end

      private

      def validate_root!(raw)
        unless raw.is_a?(Hash)
          raise Devdash::ConfigurationError, "identity configuration must be a mapping"
        end
        required = %w[owner people]
        unknown = raw.keys.map(&:to_s) - (required + %w[role_rules repository_mappings])
        return if unknown.empty?

        raise Devdash::ConfigurationError, "unknown identity configuration key: #{unknown.first}"
      end

      def validate_person!(key, value)
        unless value.is_a?(Hash)
          raise Devdash::ConfigurationError, "person #{key} must be a mapping"
        end
        unknown = value.keys.map(&:to_s) - %w[identities role level exclude_from_cohort primary_repository]
        raise Devdash::ConfigurationError, "unknown person option for #{key}: #{unknown.first}" unless unknown.empty?
        if value.key?("exclude_from_cohort") && ![true, false].include?(value["exclude_from_cohort"])
          raise Devdash::ConfigurationError, "exclude_from_cohort for #{key} must be boolean"
        end
      end

      def normalize_identities(value, person_key:)
        unless value.is_a?(Hash)
          raise Devdash::ConfigurationError, "identities for #{person_key} must be a mapping"
        end

        seen = {}
        value.each_with_object({}) do |(source, external_id), result|
          source = source.to_s.downcase
          unless @allowed_sources.include?(source)
            raise Devdash::ConfigurationError, "unknown source #{source} for #{person_key}"
          end
          if external_id.is_a?(Hash) || external_id.is_a?(Array) || external_id.to_s.strip.empty?
            raise Devdash::ConfigurationError, "identity #{source} for #{person_key} must be a scalar"
          end
          external_id = external_id.to_s.strip
          identity_key = [source, external_id]
          if seen.key?(identity_key) || @people&.values&.any? { |person| person.identities[ source ] == external_id }
            raise Devdash::ConfigurationError, "duplicate external identity #{source}:#{external_id}"
          end
          # The second check above catches people parsed earlier; this check
          # catches duplicate identities in the current person too.
          if @identity_keys&.include?(identity_key)
            raise Devdash::ConfigurationError, "duplicate external identity #{source}:#{external_id}"
          end
          @identity_keys ||= []
          @identity_keys << identity_key
          seen[identity_key] = true
          result[source] = external_id
        end
      end

      def normalize_role_rules(value)
        unless value.is_a?(Array)
          raise Devdash::ConfigurationError, "role_rules must be a list"
        end
        seen = {}
        value.each_with_index.map do |rule, index|
          unless rule.is_a?(Hash)
            raise Devdash::ConfigurationError, "role rule #{index + 1} must be a mapping"
          end
          unknown = rule.keys.map(&:to_s) - %w[id pattern role level]
          raise Devdash::ConfigurationError, "unknown role rule option: #{unknown.first}" unless unknown.empty?
          raw_pattern = rule.fetch("pattern")
          if raw_pattern.is_a?(Hash) || raw_pattern.is_a?(Array)
            raise Devdash::ConfigurationError, "role rule pattern must be scalar"
          end
          pattern = raw_pattern.to_s
          regexp = Regexp.new(pattern)
          role = optional_string(rule.fetch("role"))
          level = optional_string(rule.fetch("level"))
          raise Devdash::ConfigurationError, "role and level are required" if role.nil? || level.nil?
          key = [pattern, regexp.options]
          if seen.key?(key) && seen[key] != [role, level]
            raise Devdash::ConfigurationError, "contradictory overlapping role rules for #{pattern.inspect}"
          end
          seen[key] = [role, level]
          { id: (rule["id"] || "rule-#{index + 1}").to_s, pattern: regexp, role:, level: }.freeze
        rescue KeyError => error
          raise Devdash::ConfigurationError, "role rule #{index + 1} missing #{error.key}"
        rescue RegexpError => error
          raise Devdash::ConfigurationError, "invalid regular expression in role rule #{index + 1}: #{error.message}"
        end.freeze
      end

      def validate_repository_mappings!
        unless @repository_mappings.is_a?(Hash)
          raise Devdash::ConfigurationError, "repository_mappings must be a mapping"
        end
        @repository_mappings.each do |kind, mappings|
          next if kind.to_s == "enable_identifier_tokens"
          next unless mappings.is_a?(Hash)

          mappings.each_value do |selector|
            Array(selector).each { |item| repository_for(item) if item.is_a?(String) }
          end
        end
        if @repository_mappings["enable_identifier_tokens"] && ![true, false].include?(@repository_mappings["enable_identifier_tokens"])
          raise Devdash::ConfigurationError, "enable_identifier_tokens must be boolean"
        end
      end

      def validate_primary_mapping_conflicts!
        %w[primary_issues issue_primary].each do |key|
          mapping = @repository_mappings[key]
          next unless mapping.is_a?(Hash)

          mapping.each_key do |identifier|
            next unless @repository_mappings["primary_issues"].is_a?(Hash) &&
              @repository_mappings["issue_primary"].is_a?(Hash) &&
              @repository_mappings["primary_issues"].key?(identifier) &&
              @repository_mappings["issue_primary"].key?(identifier)
            next if @repository_mappings["primary_issues"][identifier] == @repository_mappings["issue_primary"][identifier]

            raise Devdash::ConfigurationError, "contradictory primary repository mappings for #{identifier}"
          end
        end
      end

      def optional_string(value)
        return if value.nil?
        raise Devdash::ConfigurationError, "identity configuration values must be scalar" if value.is_a?(Hash) || value.is_a?(Array)

        value = value.to_s.strip
        value unless value.empty?
      end

      def deep_copy(value)
        case value
        when Hash then value.each_with_object({}) { |(key, item), copy| copy[key.to_s] = deep_copy(item) }
        when Array then value.map { |item| deep_copy(item) }
        else value
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, item| deep_freeze(key); deep_freeze(item) }
        when Array then value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end
  end
end
