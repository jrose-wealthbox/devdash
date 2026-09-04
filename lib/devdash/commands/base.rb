# frozen_string_literal: true

require "optparse"
require "pathname"

module Devdash
  module Commands
    class UsageError < Devdash::Error; end

    class Base
      attr_reader :configuration, :out, :err

      def initialize(configuration: nil, out: $stdout, err: $stderr, database: Devdash::Database,
                     clock: -> { Time.now.utc })
        @configuration = configuration
        @out = out
        @err = err
        @database = database
        @clock = clock
      end

      private

      attr_reader :database, :clock

      def load_configuration
        @configuration ||= Configuration.load(path: ENV.fetch("DEVDASH_CONFIG", Devdash.root.join("config/devdash.yml")))
      end

      def connect_database!
        database.connect!(path: load_configuration.database_path)
        database.migrate!
      end

      def sync_repositories!
        return unless ActiveRecord::Base.connected?

        load_configuration.repositories.each do |configured|
          repository = Models::Repository.find_or_initialize_by(full_name: configured.name)
          repository.assign_attributes(source: "github", alias_name: configured.alias_name,
            enabled: configured.enabled, default_report: configured.default)
          repository.save!
        end
      end

      def repository_scope(selector = nil)
        load_configuration.resolve_repository_scope(selector)
      end

      def identity_configuration(required: false)
        path = ENV.fetch("DEVDASH_PEOPLE_CONFIG", Devdash.root.join("config/people.yml"))
        unless File.file?(path.to_s)
          raise ConfigurationError, "identity configuration not found: #{path}" if required
          return nil
        end
        config = load_configuration
        Identity::ManualConfiguration.load(path:, repository_aliases: config.repositories.map(&:alias_name),
          repository_names: config.repositories.map(&:name))
      end

      def owner_from_identity!(identity)
        raise ConfigurationError, "identity configuration is required to resolve the owner" unless identity
        owner = Models::Person.find_by(owner: true)
        raise ConfigurationError, "configured owner has not been collected yet" unless owner

        owner
      end

      def prepare_database!
        connect_database!
        sync_repositories!
      end

      def metric_registry
        Devdash.build_metric_registry(persist: true)
      end

      def normalize_source_failures(error)
        message = error.message.to_s.gsub(/(token|authorization|api[_-]?key)\s*[:=]\s*\S+/i, '\\1=[redacted]')
        message.empty? ? error.class.name : message
      end
    end
  end
end
