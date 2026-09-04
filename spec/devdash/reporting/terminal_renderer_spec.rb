# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/devdash/reporting/terminal_renderer"

RSpec.describe Devdash::Reporting::TerminalRenderer do
  it "renders stable section headers, explicit units, unavailable values, and small samples" do
    scope = Devdash::RepositoryScope.new(key: "crm-web", repository_names: ["acme/crm-web"], label: "crm-web", configuration_hash: "x")
    window = Devdash::Metrics::Window.for("7d", end_at: Time.utc(2026, 9, 3))
    report = Devdash::Reporting::Report.new(
      owner: { "display_name" => "John" }, reported_at: window.end_at, window:, previous_window: window.previous,
      repository_scope: scope, cohort: {}, sections: {
        "speed" => [{ name: "Merged PRs", signal_role: "outcome", unit: "pull requests",
                      current: { value: 4 }, previous: { value: 3 }, comparison: { absolute_delta: 1, statistics: { n: 2, median: 3 } }, breakdown: {} }],
        "ease" => [], "quality" => [], "thriving" => []
      }, coverage: {}, freshness: {}, framework_coverage: {
        "space" => { "status" => "measured", "dimensions" => {} }, "devex" => { "status" => "partial", "dimensions" => {} },
        "dora" => { "status" => "unavailable", "reason" => "unavailable in V1 (service-level source not configured)" },
        "thriving" => { "status" => "unavailable", "reason" => "unavailable until private self-report is configured" }
      }, partial_data_reasons: [], cache_key: nil, cached: false
    )

    output = described_class.new.render(report)

    expect(output).to include("Personal Engineering Dashboard · 7d · crm-web")
    expect(output).to include("Current: 2026-08-27 00:00Z → 2026-09-03 00:00Z")
    expect(output).to include("Merged PRs")
    expect(output).to include("insufficient peer sample (n=2)")
    expect(output).to include("DORA: unavailable in V1 (service-level source not configured)")
    expect(output).not_to include("\\e[")
  end
end
