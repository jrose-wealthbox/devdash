# frozen_string_literal: true
module Devdash
  module Models
    class CommitFile < BaseRecord
      belongs_to :commit
    end
  end
end
