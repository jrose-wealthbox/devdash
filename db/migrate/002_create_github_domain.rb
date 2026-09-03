# frozen_string_literal: true

class CreateGithubDomain < ActiveRecord::Migration[8.1]
  def change
    create_table :pull_requests do |t|
      t.references :repository, null: false, foreign_key: true
      t.integer :number, null: false
      t.string :node_id
      t.references :author, foreign_key: { to_table: :people }
      t.string :author_login
      t.string :state, null: false
      t.boolean :draft, null: false, default: false
      t.string :base_branch
      t.string :head_sha
      t.string :merge_sha
      t.datetime :opened_at
      t.datetime :closed_at
      t.datetime :merged_at
      t.datetime :source_updated_at
      t.integer :additions
      t.integer :deletions
      t.integer :changed_files_count
      t.timestamps
    end
    add_index :pull_requests, %i[repository_id number], unique: true
    add_index :pull_requests, :node_id, unique: true, where: "node_id IS NOT NULL"
    add_index :pull_requests, %i[repository_id source_updated_at]
    add_index :pull_requests, %i[repository_id opened_at]
    add_index :pull_requests, %i[repository_id closed_at]
    add_index :pull_requests, %i[repository_id merged_at]

    create_table :pull_request_events do |t|
      t.references :pull_request, null: false, foreign_key: true
      t.string :stable_external_id, null: false
      t.string :kind, null: false
      t.references :actor, foreign_key: { to_table: :people }
      t.string :actor_login
      t.references :subject, foreign_key: { to_table: :people }
      t.string :subject_login
      t.datetime :occurred_at
      t.string :derivation
      t.timestamps
    end
    add_index :pull_request_events, %i[pull_request_id stable_external_id], unique: true, name: "idx_pr_events_pr_external"
    add_index :pull_request_events, %i[pull_request_id occurred_at]
    add_index :pull_request_events, :occurred_at

    create_table :pull_request_reviews do |t|
      t.references :pull_request, null: false, foreign_key: true
      t.string :github_review_id, null: false
      t.references :reviewer, foreign_key: { to_table: :people }
      t.string :reviewer_login
      t.string :state
      t.datetime :submitted_at
      t.timestamps
    end
    add_index :pull_request_reviews, :github_review_id, unique: true
    add_index :pull_request_reviews, %i[pull_request_id submitted_at]
    add_index :pull_request_reviews, :submitted_at

    create_table :pull_request_files do |t|
      t.references :pull_request, null: false, foreign_key: true
      t.string :path, null: false
      t.string :status
      t.integer :additions, null: false, default: 0
      t.integer :deletions, null: false, default: 0
      t.string :exclusion_category
      t.timestamps
    end
    add_index :pull_request_files, %i[pull_request_id path], unique: true

    create_table :commits do |t|
      t.references :repository, null: false, foreign_key: true
      t.string :sha, null: false
      t.references :author, foreign_key: { to_table: :people }
      t.references :committer, foreign_key: { to_table: :people }
      t.string :author_login
      t.string :author_email
      t.string :committer_login
      t.string :committer_email
      t.datetime :authored_at
      t.datetime :committed_at
      t.integer :parent_count, null: false, default: 0
      t.boolean :default_branch_reachable, null: false, default: false
      t.references :pull_request, foreign_key: true
      t.timestamps
    end
    add_index :commits, %i[repository_id sha], unique: true
    add_index :commits, %i[repository_id authored_at]
    add_index :commits, %i[repository_id committed_at]
    add_index :commits, :default_branch_reachable

    create_table :commit_files do |t|
      t.references :commit, null: false, foreign_key: true
      t.string :path, null: false
      t.string :status
      t.integer :additions, null: false, default: 0
      t.integer :deletions, null: false, default: 0
      t.string :exclusion_category
      t.timestamps
    end
    add_index :commit_files, %i[commit_id path], unique: true
  end
end
