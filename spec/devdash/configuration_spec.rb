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

  it "rejects duplicate fully-qualified repository names" do
    Dir.mktmpdir do |directory|
      duplicate = valid_yaml.sub("name: starburstlabs/repo1", "name: starburstlabs/crm-web")
      expect { described_class.load(path: write_config(directory, duplicate)) }
        .to raise_error(Devdash::ConfigurationError, /repository names must be unique/)
    end
  end

  it "rejects an empty YAML document with a configuration error" do
    Dir.mktmpdir do |directory|
      expect { described_class.load(path: write_config(directory, "")) }
        .to raise_error(Devdash::ConfigurationError, /configuration must be a mapping/)
    end
  end

  it "rejects a non-mapping repository entry with a configuration error" do
    Dir.mktmpdir do |directory|
      malformed = <<~YAML
        database_path: data/devdash.sqlite3
        github:
          repositories:
            - name: starburstlabs/crm-web
              alias: crm-web
              default: true
            - repo1
      YAML
      expect { described_class.load(path: write_config(directory, malformed)) }
        .to raise_error(Devdash::ConfigurationError, /repository entry 2 must be a mapping/)
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

  it "rejects an explicitly selected disabled repository" do
    Dir.mktmpdir do |directory|
      disabled = <<~YAML
        database_path: data/devdash.sqlite3
        github:
          repositories:
            - name: starburstlabs/crm-web
              alias: crm-web
              default: true
            - name: starburstlabs/repo1
              alias: repo1
              enabled: false
      YAML
      config = described_class.load(path: write_config(directory, disabled))

      expect { config.resolve_repository_scope("repo1") }
        .to raise_error(Devdash::ConfigurationError, /unknown or disabled repository: repo1/)
    end
  end

  it "rejects a non-boolean repository default" do
    Dir.mktmpdir do |directory|
      malformed = valid_yaml.sub("default: true", 'default: "false"')

      expect { described_class.load(path: write_config(directory, malformed)) }
        .to raise_error(Devdash::ConfigurationError, /default must be a boolean/)
    end
  end

  it "rejects a non-boolean repository enabled flag" do
    Dir.mktmpdir do |directory|
      malformed = valid_yaml.sub("enabled: true", 'enabled: "false"')

      expect { described_class.load(path: write_config(directory, malformed)) }
        .to raise_error(Devdash::ConfigurationError, /enabled must be a boolean/)
    end
  end

  it "loads conservative sync defaults and validates configured exclusions" do
    Dir.mktmpdir do |directory|
      config = described_class.load(path: write_config(directory, valid_yaml))
      expect(config).to have_attributes(overlap_seconds: 172800, initial_backfill_days: 360,
        safety_margin_days: 7, freshness_seconds: 172800, file_exclusions: {})

      malformed = valid_yaml.sub("github:", "sync:\n  file_exclusions: bad\ngithub:")
      expect { described_class.load(path: write_config(directory, malformed)) }
        .to raise_error(Devdash::ConfigurationError, /file_exclusions/)
    end
  end
end
