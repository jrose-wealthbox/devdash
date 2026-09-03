# frozen_string_literal: true

class AddLinearIssueSourceTimestampIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :linear_issues, :created_at_source
    add_index :linear_issues, :started_at_source
    add_index :linear_issues, :canceled_at_source
  end
end
