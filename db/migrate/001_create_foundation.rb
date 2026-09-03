# frozen_string_literal: true

class CreateFoundation < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :people do |t|
      t.references :organization, foreign_key: true
      t.references :merged_into, foreign_key: { to_table: :people }
      t.string :display_name, null: false
      t.boolean :active, null: false, default: true
      t.boolean :human, null: false, default: true
      t.boolean :bot, null: false, default: false
      t.boolean :guest, null: false, default: false
      t.boolean :owner, null: false, default: false
      t.timestamps
    end
    add_index :people, :owner, unique: true, where: "owner = 1"

    create_table :source_identities do |t|
      t.references :person, null: false, foreign_key: true
      t.string :source, null: false
      t.string :external_id, null: false
      t.string :login
      t.string :normalized_email
      t.string :observed_display_name
      t.string :resolution_method, null: false, default: "unresolved"
      t.decimal :confidence, precision: 4, scale: 3
      t.datetime :first_observed_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :last_observed_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamps
    end
    add_index :source_identities, %i[source external_id], unique: true

    create_table :role_assignments do |t|
      t.references :person, null: false, foreign_key: true
      t.string :source, null: false
      t.string :original_title, null: false
      t.string :normalized_role
      t.string :normalized_level
      t.datetime :effective_from, null: false
      t.datetime :effective_until
      t.datetime :observed_at, null: false
      t.timestamps
    end

    create_table :repositories do |t|
      t.string :source, null: false, default: "github"
      t.string :external_id
      t.string :full_name, null: false
      t.string :alias_name, null: false
      t.string :default_branch
      t.boolean :enabled, null: false, default: true
      t.boolean :default_report, null: false, default: false
      t.boolean :archived, null: false, default: false
      t.text :metadata_json
      t.timestamps
    end
    add_index :repositories, :full_name, unique: true
    add_index :repositories, :alias_name, unique: true
    add_index :repositories, :default_report, unique: true, where: "default_report = 1"

    create_table :collector_runs do |t|
      t.string :source, null: false
      t.string :scope_key, null: false
      t.string :status, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.string :cursor_before
      t.string :cursor_after
      t.integer :page_count, null: false, default: 0
      t.integer :record_count, null: false, default: 0
      t.integer :retry_count, null: false, default: 0
      t.string :error_class
      t.text :error_message
      t.timestamps
    end

    create_table :collector_run_coverages do |t|
      t.references :collector_run, null: false, foreign_key: true
      t.string :scope_type, null: false
      t.string :scope_key, null: false
      t.string :entity_type, null: false
      t.datetime :requested_start_at
      t.datetime :requested_end_at
      t.datetime :achieved_start_at
      t.datetime :achieved_end_at
      t.string :status, null: false
      t.timestamps
    end

    create_table :sync_cursors do |t|
      t.string :source, null: false
      t.string :scope_key, null: false
      t.string :cursor_type, null: false
      t.text :cursor_value
      t.datetime :last_succeeded_at
      t.timestamps
    end
    add_index :sync_cursors, %i[source scope_key cursor_type], unique: true

    create_table :source_records do |t|
      t.references :collector_run, null: false, foreign_key: true
      t.string :source, null: false
      t.string :scope_key, null: false
      t.string :entity_type, null: false
      t.string :external_id, null: false
      t.datetime :source_updated_at
      t.datetime :observed_at, null: false
      t.string :api_version
      t.string :query_fingerprint, null: false
      t.integer :normalizer_version
      t.string :payload_hash, null: false
      t.text :payload_json, null: false
      t.timestamps
    end
    add_index :source_records, %i[source scope_key entity_type external_id payload_hash],
      unique: true, name: "idx_source_records_identity_and_hash"

    create_table :normalization_runs do |t|
      t.string :normalizer_key, null: false
      t.integer :normalizer_version, null: false
      t.integer :source_record_watermark
      t.string :status, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer :input_count, null: false, default: 0
      t.integer :output_count, null: false, default: 0
      t.string :error_class
      t.text :error_message
      t.timestamps
    end

    create_table :person_merge_audits do |t|
      t.references :source_person, null: false, foreign_key: { to_table: :people, on_delete: :restrict }
      t.references :destination_person, null: false, foreign_key: { to_table: :people, on_delete: :restrict }
      t.string :reason, null: false
      t.string :evidence_reference, null: false
      t.datetime :merged_at, null: false
      t.timestamps
    end
  end
end
