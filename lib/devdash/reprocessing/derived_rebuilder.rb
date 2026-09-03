# frozen_string_literal: true

module Devdash
  module Reprocessing
    class DerivedRebuilder
      def initialize(cache_models: [])
        @cache_models = cache_models
      end

      def call
        validate_cache_models!
        deleted = 0
        ActiveRecord::Base.transaction do
          @cache_models.each { |model| deleted += model.delete_all }
        end
        deleted
      end

      private

      def validate_cache_models!
        invalid = @cache_models.reject do |model|
          model.respond_to?(:disposable_derived_cache?) && model.disposable_derived_cache? == true
        end
        return if invalid.empty?

        raise ArgumentError, "all cache models must declare disposable derived cache contract"
      end
    end
  end
end
