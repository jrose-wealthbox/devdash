# frozen_string_literal: true

module Devdash
  module Models
    class SourceIdentity < BaseRecord
      belongs_to :person
      validates :source, :external_id, presence: true
    end
  end
end
