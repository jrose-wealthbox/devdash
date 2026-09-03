# frozen_string_literal: true

require "pathname"

module Devdash
  class Error < StandardError; end
  class ConfigurationError < Error; end

  def self.root
    @root ||= Pathname(__dir__).join("..").expand_path
  end
end

require_relative "devdash/repository_scope"
require_relative "devdash/configuration"
require_relative "devdash/database"
require_relative "devdash/models/base_record"
require_relative "devdash/models/organization"
require_relative "devdash/models/person"
require_relative "devdash/models/person_merge_audit"
require_relative "devdash/models/source_identity"
require_relative "devdash/models/role_assignment"
require_relative "devdash/models/repository"
require_relative "devdash/models/collector_run"
require_relative "devdash/models/collector_run_coverage"
require_relative "devdash/models/sync_cursor"
require_relative "devdash/models/source_record"
require_relative "devdash/models/normalization_run"
