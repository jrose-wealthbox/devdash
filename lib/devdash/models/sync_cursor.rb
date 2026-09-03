# frozen_string_literal: true

module Devdash
  module Models
    class SyncCursor < BaseRecord
      validates :source, :scope_key, :cursor_type, presence: true
    end
  end
end
