# frozen_string_literal: true

class CreateMetricMetadataAndReportCache < ActiveRecord::Migration[8.1]
  def change
    create_table :metric_definitions do |t|
      t.string :key, null: false
      t.integer :version, null: false
      t.string :name, null: false
      t.text :description, null: false
      t.string :unit, null: false
      t.string :value_type, null: false
      t.string :signal_role, null: false
      t.string :measurement_scope, null: false
      t.string :collection_mode, null: false
      t.string :directionality, null: false
      t.string :comparison_mode, null: false, default: "person"
      t.string :engthrive_section, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :metric_definitions, %i[key version], unique: true
    add_index :metric_definitions, :active

    create_table :metric_framework_mappings do |t|
      t.references :metric_definition, null: false, foreign_key: true
      t.string :framework, null: false
      t.string :dimension, null: false
      t.string :status, null: false
      t.timestamps
    end
    add_index :metric_framework_mappings, %i[metric_definition_id framework dimension],
      unique: true, name: "idx_metric_framework_mappings_unique"

    create_table :report_snapshots do |t|
      t.string :cache_key, null: false
      t.datetime :window_start_at, null: false
      t.datetime :window_end_at, null: false
      t.string :repository_scope_hash, null: false
      t.string :cohort_hash, null: false
      t.string :metric_versions_hash, null: false
      t.string :source_watermark_hash, null: false
      t.integer :format_version, null: false
      t.text :structured_json, null: false
      t.text :rendered_text
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    add_index :report_snapshots, :cache_key, unique: true
  end
end
