# frozen_string_literal: true

RSpec.describe Devdash::Database do
  it "migrates an empty SQLite database and enables foreign keys" do
    connect_test_database!
    tables = ActiveRecord::Base.connection.tables
    expect(tables).to include("people", "source_records", "sync_cursors")
    expect(ActiveRecord::Base.connection.select_value("PRAGMA foreign_keys")).to eq(1)
  end

  it "enforces one external identity per source ID" do
    connect_test_database!
    person = Devdash::Models::Person.create!(display_name: "John", human: true, owner: true)
    attributes = { person:, source: "github", external_id: "U_1", login: "john" }
    Devdash::Models::SourceIdentity.create!(attributes)
    expect { Devdash::Models::SourceIdentity.create!(attributes) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end
