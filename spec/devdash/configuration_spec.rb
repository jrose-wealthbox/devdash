# frozen_string_literal: true

RSpec.describe Devdash::Configuration do
  def write_config(directory, yaml)
    path = File.join(directory, "devdash.yml")
    File.write(path, yaml)
    path
  end

  let(:valid_yaml) do
    <<~YAML
      database_path: data/devdash.sqlite3
      github:
        repositories:
          - name: starburstlabs/crm-web
            alias: crm-web
            default: true
            enabled: true
          - name: starburstlabs/repo1
            alias: repo1
            enabled: true
    YAML
  end

  it "requires exactly one enabled default repository" do
    Dir.mktmpdir do |directory|
      path = write_config(directory, valid_yaml.gsub("default: true", "default: false"))
      expect { described_class.load(path:) }
        .to raise_error(Devdash::ConfigurationError, /exactly one enabled default/)
    end
  end

  it "rejects duplicate and reserved aliases" do
    Dir.mktmpdir do |directory|
      duplicate = valid_yaml.sub("alias: repo1", "alias: crm-web")
      expect { described_class.load(path: write_config(directory, duplicate)) }
        .to raise_error(Devdash::ConfigurationError, /unique/)

      reserved = valid_yaml.sub("alias: repo1", "alias: all")
      expect { described_class.load(path: write_config(directory, reserved)) }
        .to raise_error(Devdash::ConfigurationError, /reserved/)
    end
  end

  it "resolves omitted, named, fully-qualified, and all scopes" do
    Dir.mktmpdir do |directory|
      config = described_class.load(path: write_config(directory, valid_yaml))
      expect(config.resolve_repository_scope.repository_names).to eq(["starburstlabs/crm-web"])
      expect(config.resolve_repository_scope("repo1").repository_names).to eq(["starburstlabs/repo1"])
      expect(config.resolve_repository_scope("starburstlabs/repo1").key).to eq("repo1")
      expect(config.resolve_repository_scope("all").repository_names)
        .to eq(["starburstlabs/crm-web", "starburstlabs/repo1"])
      expect(config.resolve_repository_scope("all").label).to eq("All configured repos (2)")
    end
  end
end
