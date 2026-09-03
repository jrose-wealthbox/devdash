# frozen_string_literal: true

module Devdash
  module Models
    class Organization < BaseRecord
      has_many :people, dependent: :restrict_with_exception
      validates :name, presence: true
    end
  end
end
