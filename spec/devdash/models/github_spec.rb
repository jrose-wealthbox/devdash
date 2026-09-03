# frozen_string_literal: true
require "devdash/models/pull_request"
require "devdash/models/pull_request_event"
require "devdash/models/pull_request_review"
require "devdash/models/pull_request_file"
require "devdash/models/commit"
require "devdash/models/commit_file"

RSpec.describe "GitHub schema" do
  it "creates repository-qualified canonical tables" do
    connect_test_database!
    expect(ActiveRecord::Base.connection.tables).to include("pull_requests", "pull_request_events", "pull_request_reviews", "pull_request_files", "commits", "commit_files")
    expect(Devdash::Models::PullRequest.connection.index_exists?(:pull_requests, [:repository_id, :number], unique: true)).to be(true)
    expect(Devdash::Models::Commit.connection.index_exists?(:commits, [:repository_id, :sha], unique: true)).to be(true)
  end
end
