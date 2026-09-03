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

  it "defensively freezes repository names supplied to the constructor" do
    repository_names = ["starburstlabs/crm-web"]
    constructed_scope = described_class.new(
      key: "crm-web",
      repository_names:,
      label: "crm-web",
      configuration_hash: "abc"
    )

    expect(constructed_scope.repository_names).to be_frozen
    expect { repository_names << "starburstlabs/repo1" }.not_to raise_error
    expect(repository_names).to eq(["starburstlabs/crm-web", "starburstlabs/repo1"])
    expect(constructed_scope.repository_names).to eq(["starburstlabs/crm-web"])
    expect { constructed_scope.repository_names << "starburstlabs/repo1" }.to raise_error(FrozenError)
  end
end
