# frozen_string_literal: true

module Devdash
  module Models
    class RoleAssignment < BaseRecord
      belongs_to :person
      validates :source, :original_title, :effective_from, :observed_at, presence: true
    end
  end
end
