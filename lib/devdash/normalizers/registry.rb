# frozen_string_literal: true

module Devdash
  module Normalizers
    module Registry
      module_function

      def register(source:, entity_type:, normalizer:)
        key = [source.to_s, entity_type.to_s].freeze
        raise ArgumentError, "normalizer already registered for #{key.join(":")}" if normalizers.key?(key)
        raise ArgumentError, "normalizer must expose version and call" unless normalizer.respond_to?(:version) && normalizer.respond_to?(:call)

        normalizers[key] = normalizer
      end

      def fetch(source:, entity_type:)
        normalizers.fetch([source.to_s, entity_type.to_s]) do
          raise KeyError, "no normalizer registered for #{source}:#{entity_type}"
        end
      end

      def each(&block)
        normalizers.each(&block)
      end

      def clear!
        normalizers.clear
      end

      def normalizers
        @normalizers ||= {}
      end
      private_class_method :normalizers
    end
  end
end
