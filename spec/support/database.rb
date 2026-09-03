# frozen_string_literal: true

require "tmpdir"

def connect_test_database!
  @test_database_directory ||= Dir.mktmpdir("devdash-spec-")
  database_path = File.join(@test_database_directory, "test.sqlite3")
  Devdash::Database.connect!(path: database_path)
  Devdash::Database.migrate!
end

RSpec.configure do |config|
  config.after do
    ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
  end
end
