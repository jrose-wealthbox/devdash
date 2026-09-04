# frozen_string_literal: true

require "yaml"
require "pathname"

module Devdash
  class Configuration
    Repository = Data.define(:name, :alias_name, :default, :enabled)

    attr_reader :database_path, :repositories, :overlap_seconds, :initial_backfill_days, :safety_margin_days,
      :file_exclusions, :freshness_seconds

    def self.load(path: Devdash.root.join("config/devdash.yml"))
      raw = YAML.safe_load_file(path.to_s, permitted_classes: [], aliases: false)
      new(raw:, config_path: Pathname(path))
    rescue Errno::ENOENT => error
      raise ConfigurationError, "configuration not found: #{error.message}"
    rescue Psych::Exception => error
      raise ConfigurationError, "invalid YAML: #{error.message}"
    end

    def initialize(raw:, config_path:)
      @config_path = config_path
      unless raw.is_a?(Hash)
        raise ConfigurationError, "configuration must be a mapping"
      end

      github = raw.fetch("github", {})
      unless github.is_a?(Hash)
        raise ConfigurationError, "github configuration must be a mapping"
      end

      repository_items = github.fetch("repositories", [])
      unless repository_items.is_a?(Array)
        raise ConfigurationError, "github.repositories must be an array"
      end

      @database_path = expand_path(raw.fetch("database_path", "data/devdash.sqlite3"))
      sync = raw.fetch("sync", {})
      unless sync.is_a?(Hash)
        raise ConfigurationError, "sync configuration must be a mapping"
      end
      @overlap_seconds = positive_or_zero_integer(sync.fetch("overlap_seconds", 48 * 3600), "overlap_seconds")
      @initial_backfill_days = positive_integer(sync.fetch("initial_backfill_days", 360), "initial_backfill_days")
      @safety_margin_days = positive_or_zero_integer(sync.fetch("safety_margin_days", 7), "safety_margin_days")
      exclusions = sync.fetch("file_exclusions", {})
      unless exclusions.is_a?(Hash) && exclusions.all? { |category, patterns| !category.to_s.strip.empty? && Array(patterns).all? { |pattern| pattern.is_a?(String) && !pattern.strip.empty? } }
        raise ConfigurationError, "file_exclusions must map categories to non-empty string patterns"
      end
      @file_exclusions = exclusions.transform_keys(&:to_s).transform_values { |patterns| Array(patterns).map(&:dup).freeze }.freeze
      @freshness_seconds = positive_or_zero_integer(sync.fetch("freshness_seconds", 2 * 86_400), "freshness_seconds")
      @repositories = repository_items.each_with_index.map do |item, index|
        unless item.is_a?(Hash)
          raise ConfigurationError, "repository entry #{index + 1} must be a mapping"
        end

        name = item.fetch("name")
        alias_name = item.fetch("alias")
        unless name.is_a?(String) && alias_name.is_a?(String)
          raise ConfigurationError, "repository entry #{index + 1} name and alias must be strings"
        end

        default = item.fetch("default", false)
        enabled = item.fetch("enabled", true)
        unless default == true || default == false
          raise ConfigurationError, "repository entry #{index + 1} default must be a boolean"
        end
        unless enabled == true || enabled == false
          raise ConfigurationError, "repository entry #{index + 1} enabled must be a boolean"
        end

        Repository.new(
          name:,
          alias_name:,
          default:,
          enabled:
        )
      end.freeze
      validate!
    rescue KeyError, TypeError => error
      raise ConfigurationError, "invalid configuration: #{error.message}"
    end

    def resolve_repository_scope(selector = nil)
      enabled = repositories.select(&:enabled)
      selected = selector || enabled.find(&:default)&.alias_name
      raise ConfigurationError, "exactly one enabled default repository is required" unless selected

      members = if selected == "all"
        enabled
      else
        [enabled.find { |repository| [repository.alias_name, repository.name].include?(selected) } ||
          raise(ConfigurationError, "unknown or disabled repository: #{selected}")]
      end
      names = members.map(&:name).sort.freeze
      label = selected == "all" ? "All configured repos (#{names.length})" : members.fetch(0).alias_name
      RepositoryScope.new(
        key: selected == "all" ? "all" : members.fetch(0).alias_name,
        repository_names: names,
        label:,
        configuration_hash: Digest::SHA256.hexdigest(JSON.generate(names))
      )
    end

    private

    def positive_integer(value, name)
      parsed = Integer(value)
      raise ConfigurationError, "#{name} must be positive" unless parsed.positive?

      parsed
    rescue ArgumentError, TypeError
      raise ConfigurationError, "#{name} must be an integer"
    end

    def positive_or_zero_integer(value, name)
      parsed = Integer(value)
      raise ConfigurationError, "#{name} must be non-negative" if parsed.negative?

      parsed
    rescue ArgumentError, TypeError
      raise ConfigurationError, "#{name} must be an integer"
    end

    def expand_path(value)
      return Pathname(":memory:") if value.to_s == ":memory:"

      Pathname(value).absolute? ? Pathname(value) : Devdash.root.join(value)
    end

    def validate!
      enabled = repositories.select(&:enabled)
      raise ConfigurationError, "exactly one enabled default repository is required" unless enabled.count(&:default) == 1

      aliases = repositories.map(&:alias_name)
      raise ConfigurationError, "repository aliases must be unique" unless aliases.uniq.length == aliases.length
      names = repositories.map(&:name)
      raise ConfigurationError, "repository names must be unique" unless names.uniq.length == names.length
      raise ConfigurationError, "repository alias 'all' is reserved" if aliases.include?("all")

      invalid = repositories.reject { |repository| repository.name.match?(%r{\A[^/]+/[^/]+\z}) }
      raise ConfigurationError, "repository names must use owner/name" if invalid.any?
    end
  end
end
