# frozen_string_literal: true

require "digest"
require "json"

module Devdash
  module Ingestion
    module CanonicalJson
      module_function

      def dump(value)
        JSON.generate(canonicalize(value))
      end

      def sha256(value)
        Digest::SHA256.hexdigest(dump(value))
      end

      def canonicalize(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), result| result[key.to_s] = canonicalize(child) }
            .sort_by { |key, _| key }
            .to_h
        when Array
          value.map { |child| canonicalize(child) }
        else
          value
        end
      end
      private_class_method :canonicalize
    end
  end
end
