# frozen_string_literal: true

require "open3"

RSpec.describe "devdash CLI" do
  it "prints help without requiring configuration" do
    stdout, stderr, status = Open3.capture3("mise", "exec", "--", "ruby", "bin/devdash", "--help", chdir: Devdash.root.to_s)

    expect(status).to be_success
    expect(stdout).to include("Usage:")
    expect(stderr).to be_empty
  end

  it "prints subcommand help without requiring configuration" do
    %w[report doctor].each do |command|
      stdout, stderr, status = Open3.capture3("mise", "exec", "--", "ruby", "bin/devdash", command, "--help", chdir: Devdash.root.to_s)

      expect(status).to be_success
      expect(stdout).to include("Usage: devdash #{command}")
      expect(stderr).to be_empty
    end
  end
end
