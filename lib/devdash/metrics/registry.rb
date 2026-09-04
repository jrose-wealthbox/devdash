# frozen_string_literal: true

require "active_record"
require_relative "definition"
require_relative "../models/metric_definition"
require_relative "../models/metric_framework_mapping"

module Devdash
  module Metrics
    class Registry
      Entry = Data.define(:query, :definition, :display_order) do
        def call(**kwargs, &block)
          query.call(**kwargs, &block)
        end

        def key
          definition.key
        end
      end

      SECTION_ORDER = { "speed" => 0, "ease" => 1, "quality" => 2, "thriving" => 3 }.freeze

      def initialize(display_order: {})
        @display_order = display_order.transform_keys(&:to_s).freeze
        @entries = {}
      end

      def register(query: nil, definition: nil, display_order: nil, &factory)
        query ||= factory
        definition ||= query&.respond_to?(:definition) && query.definition
        raise ArgumentError, "metric query and definition are required" unless query && definition
        definition = Definition.new(**definition.to_h) unless definition.is_a?(Definition)
        raise ArgumentError, "metric key #{definition.key.inspect} is already registered" if @entries.key?(definition.key)
        validate_framework_mappings!(definition)
        order = display_order.nil? ? @display_order.fetch(definition.key, 0) : Integer(display_order)
        @entries[definition.key] = Entry.new(query:, definition:, display_order: order)
      rescue TypeError, ArgumentError => error
        raise error if error.message.include?("metric") || error.message.include?("framework")
        raise ArgumentError, "display order must be an integer"
      end

      def fetch(key)
        @entries.fetch(key.to_s) { raise KeyError, "unknown metric #{key.inspect}" }
      end

      def key?(key)
        @entries.key?(key.to_s)
      end

      def entries
        @entries.values.sort_by { |entry| sort_key(entry) }
      end

      def active_definitions
        entries.filter_map { |entry| entry.definition if active?(entry.definition) }
      end

      def persist!
        return self unless ActiveRecord::Base.connected? && ActiveRecord::Base.connection.table_exists?("metric_definitions")

        entries.each do |entry|
          definition = entry.definition
          row = Models::MetricDefinition.find_or_initialize_by(key: definition.key, version: definition.version)
          row.assign_attributes(
            name: definition.name, description: definition.description, unit: definition.unit,
            value_type: definition.value_type, signal_role: definition.signal_role,
            measurement_scope: definition.measurement_scope, collection_mode: definition.collection_mode,
            directionality: definition.directionality,
            comparison_mode: definition.measurement_scope == "service" ? "service" : "person",
            engthrive_section: definition.engthrive_section, active: true
          )
          row.save!
          definition.framework_mappings.each do |mapping|
            mapping = mapping_to_hash(mapping)
            row.framework_mappings.find_or_initialize_by(
              framework: mapping.fetch(:framework).to_s, dimension: mapping.fetch(:dimension).to_s
            ).update!(status: persisted_mapping_status(mapping[:status]))
          end
          Models::MetricDefinition.where(key: definition.key).where.not(id: row.id).update_all(active: false)
        end
        self
      end

      private

      def persisted_mapping_status(status)
        # `proxy` is meaningful in the in-memory metric definition (the
        # renderer labels it), while the metadata table intentionally stores
        # its measured/partial/planned availability vocabulary.
        status = (status || "measured").to_s
        status == "proxy" ? "measured" : status
      end

      def active?(definition)
        definition.respond_to?(:active?) ? definition.active? : true
      end

      def sort_key(entry)
        [SECTION_ORDER.fetch(entry.definition.engthrive_section.to_s, 99), entry.display_order, entry.definition.key.to_s]
      end

      def validate_framework_mappings!(definition)
        mappings = definition.framework_mappings
        unless mappings.all? { |mapping| mapping_value(mapping, :framework) && mapping_value(mapping, :dimension) }
          raise ArgumentError, "framework mappings must declare framework and dimension"
        end
        # SPACE and DevEx are the people/productivity frameworks. A metric that
        # is not explicitly mapped to either would be invisible in the report.
        applicable = mappings.map { |mapping| mapping_value(mapping, :framework) }.map(&:to_s)
        raise ArgumentError, "metric requires a SPACE or DevEx framework mapping" if applicable.empty?
        return if (applicable & %w[space devex]).any?
        return if definition.measurement_scope.to_s == "service" && applicable.include?("dora")

        raise ArgumentError, "metric requires a SPACE or DevEx framework mapping"
      end

      def mapping_to_hash(mapping)
        return mapping.transform_keys(&:to_sym) if mapping.respond_to?(:transform_keys)

        { framework: mapping_value(mapping, :framework), dimension: mapping_value(mapping, :dimension),
          status: mapping_value(mapping, :status) }
      end

      def mapping_value(mapping, key)
        if mapping.respond_to?(key)
          mapping.public_send(key)
        elsif mapping.respond_to?(:key?) && mapping.key?(key)
          mapping[key]
        elsif mapping.respond_to?(:key?) && mapping.key?(key.to_s)
          mapping[key.to_s]
        end
      end
    end
  end
end
