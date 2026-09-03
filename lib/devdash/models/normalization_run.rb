# frozen_string_literal: true

module Devdash
  module Models
    class NormalizationRun < BaseRecord
      validates :normalizer_key, :normalizer_version, :status, :started_at, presence: true
    end
  end
end
