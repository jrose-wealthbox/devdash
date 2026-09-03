# frozen_string_literal: true

require "digest"
require "json"

module Devdash
  RepositoryScope = Data.define(:key, :repository_names, :label, :configuration_hash)
end
