# frozen_string_literal: true

class FakeNormalizer
  Failure = Class.new(StandardError)

  class << self
    attr_accessor :raise_on_external_id, :calls

    def version
      1
    end

    def call(source_record)
      self.calls ||= []
      calls << source_record.external_id
      raise Failure, "normalizer failed for #{source_record.external_id}" if source_record.external_id == raise_on_external_id
    end

    def reset!
      self.raise_on_external_id = nil
      self.calls = []
    end
  end
end
