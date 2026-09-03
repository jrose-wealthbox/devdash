# frozen_string_literal: true

module Devdash
  module Reprocessing
    class DerivedRebuilder
      def initialize(cache_models: [])
        @cache_models = cache_models
      end

      def call
        deleted = 0
        ActiveRecord::Base.transaction do
          @cache_models.each { |model| deleted += model.delete_all }
        end
        deleted
      end
    end
  end
end
