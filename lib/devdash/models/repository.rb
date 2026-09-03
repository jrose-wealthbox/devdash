# frozen_string_literal: true

module Devdash
  module Models
    class Repository < BaseRecord
      has_many :source_records, dependent: :restrict_with_exception

      validates :source, :full_name, :alias_name, presence: true
      validates :full_name, format: { with: %r{\A[^/\s]+/[^/\s]+\z} }
      validates :alias_name, uniqueness: true
      validate :alias_name_is_not_all

      private

      def alias_name_is_not_all
        errors.add(:alias_name, "cannot be all") if alias_name.to_s.casecmp("all").zero?
      end
    end
  end
end
