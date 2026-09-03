# frozen_string_literal: true

require "active_record"
require "fileutils"

module Devdash
  module Database
    module_function

    def connect!(path:)
      ActiveRecord.raise_on_assign_to_attr_readonly = true
      FileUtils.mkdir_p(File.dirname(path.to_s), mode: 0o700) unless path.to_s == ":memory:"
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: path.to_s)
      connection = ActiveRecord::Base.connection
      connection.execute("PRAGMA foreign_keys = ON")
      connection.execute("PRAGMA journal_mode = WAL") unless path.to_s == ":memory:"
      connection.execute("PRAGMA busy_timeout = 5000")
      connection
    end

    def migrate!
      pool = ActiveRecord::Base.connection_pool
      ActiveRecord::MigrationContext.new(
        [Devdash.root.join("db/migrate").to_s],
        pool.schema_migration,
        pool.internal_metadata
      ).migrate
    end

    def with_connection(&block)
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
  end
end
