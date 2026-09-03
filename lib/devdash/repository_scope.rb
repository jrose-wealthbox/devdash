# frozen_string_literal: true

require "digest"
require "json"

module Devdash
  RepositoryScope = Data.define(:key, :repository_names, :label, :configuration_hash)

  class << RepositoryScope
    alias_method :build, :new

    def new(key:, repository_names:, label:, configuration_hash:)
      build(
        key:,
        repository_names: repository_names.dup.freeze,
        label:,
        configuration_hash:
      )
    end
  end
end
