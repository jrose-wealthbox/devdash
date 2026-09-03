# frozen_string_literal: true

class CreateLinearDomain < ActiveRecord::Migration[8.1]
  def change
    create_table :linear_issues do |t|
      t.string :linear_id, null: false
      t.string :identifier, null: false
      t.string :title, null: false
      t.string :team_id
      t.string :team_name
      t.string :project_id
      t.string :project_name
      t.string :state_id
      t.string :state_name
      t.string :state_type
      t.references :creator_person, foreign_key: { to_table: :people }
      t.string :creator_source_identity
      t.references :assignee_person, foreign_key: { to_table: :people }
      t.string :assignee_source_identity
      t.decimal :estimate, precision: 10, scale: 2
      t.datetime :created_at_source
      t.datetime :started_at_source
      t.datetime :completed_at_source
      t.datetime :canceled_at_source
      t.datetime :source_updated_at
      t.string :url
      t.boolean :active, null: false, default: true
      t.text :metadata_json
      t.timestamps
    end
    add_index :linear_issues, :linear_id, unique: true
    add_index :linear_issues, :identifier, unique: true
    add_index :linear_issues, :state_type
    add_index :linear_issues, :source_updated_at
    add_index :linear_issues, :completed_at_source
    add_index :linear_issues, :active

    create_table :linear_issue_events do |t|
      t.references :linear_issue, null: false, foreign_key: true
      t.string :stable_external_id, null: false
      t.string :kind, null: false
      t.references :actor_person, foreign_key: { to_table: :people }
      t.string :from_value
      t.string :to_value
      t.datetime :occurred_at, null: false
      t.string :derivation, null: false
      t.text :metadata_json
      t.timestamps
    end
    add_index :linear_issue_events, %i[linear_issue_id stable_external_id], unique: true, name: "idx_linear_events_issue_stable"
    add_index :linear_issue_events, :occurred_at
    add_index :linear_issue_events, :kind

    create_table :issue_repository_links do |t|
      t.references :linear_issue, null: false, foreign_key: true
      t.references :repository, foreign_key: true
      t.string :evidence_kind, null: false
      t.string :evidence_reference, null: false
      t.decimal :confidence, precision: 4, scale: 3
      t.boolean :primary, null: false, default: false
      t.string :resolution_status, null: false, default: "unresolved"
      t.timestamps
    end
    add_index :issue_repository_links,
      %i[linear_issue_id evidence_kind evidence_reference], unique: true, name: "idx_issue_repo_links_evidence"
    add_index :issue_repository_links, :resolution_status
    add_index :issue_repository_links, %i[linear_issue_id primary], unique: true,
      where: '"primary" = 1', name: "idx_issue_repo_links_one_primary"
  end
end
