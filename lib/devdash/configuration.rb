# frozen_string_literal: true

require "yaml"

module Devdash
  class Configuration
    Repository = Data.define(:name, :alias_name, :default, :enabled)

    attr_reader :database_path, :repositories

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
      @repositories = repository_items.each_with_index.map do |item, index|
        unless item.is_a?(Hash)
          raise ConfigurationError, "repository entry #{index + 1} must be a mapping"
        end

        name = item.fetch("name")
        alias_name = item.fetch("alias")
        unless name.is_a?(String) && alias_name.is_a?(String)
          raise ConfigurationError, "repository entry #{index + 1} name and alias must be strings"
        end

        Repository.new(
          name:,
          alias_name:,
          default: item.fetch("default", false),
          enabled: item.fetch("enabled", true)
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

    def expand_path(value)
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
