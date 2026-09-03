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
