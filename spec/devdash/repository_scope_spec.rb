# frozen_string_literal: true

RSpec.describe Devdash::RepositoryScope do
  subject(:scope) do
    described_class.new(
      key: "crm-web",
      repository_names: ["starburstlabs/crm-web"].freeze,
      label: "crm-web",
      configuration_hash: "abc"
    )
  end

  it "is immutable" do
    expect { scope.key = "other" }.to raise_error(NoMethodError)
    expect { scope.repository_names << "starburstlabs/repo1" }.to raise_error(FrozenError)
  end
end
