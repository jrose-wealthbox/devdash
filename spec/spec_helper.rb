# frozen_string_literal: true

require "tmpdir"
require "webmock/rspec"
require_relative "../lib/devdash"
require_relative "support/database"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.example_status_persistence_file_path = "tmp/rspec-examples.txt"
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.filter_run_when_matching :focus
  config.after do
    Devdash::Normalizers::Registry.clear!
    Devdash.register_source_normalizers!
  end
end

WebMock.disable_net_connect!(allow_localhost: true)
