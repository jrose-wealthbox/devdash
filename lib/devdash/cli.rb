# frozen_string_literal: true

require "optparse"

module Devdash
  class CLI
    COMMANDS = %w[sync backfill report reprocess rebuild-derived doctor].freeze

    class << self
      def start(argv, out: $stdout, err: $stderr, command_factory: nil)
        argv = Array(argv).dup
        if argv.empty? || %w[-h --help].include?(argv.first)
          out.write(help_text)
          return 0
        end

        command = argv.shift
        raise Commands::UsageError, "unknown command #{command.inspect}" unless COMMANDS.include?(command)
        factory = command_factory || method(:default_command)
        run_command(factory, command, argv, out:, err:)
      rescue Commands::UsageError, OptionParser::ParseError => error
        err.puts "Usage error: #{error.message}"
        2
      rescue Devdash::Error, ActiveRecord::ActiveRecordError, ArgumentError, KeyError => error
        err.puts "Error: #{error.message}"
        1
      end

      def help_text
        <<~TEXT
          Usage: devdash COMMAND [options]

          Commands:
            sync [github|linear|slack|all] [--repo SCOPE]
            backfill --days N [--repo SCOPE]
            report --window 7d|30d|180d [--repo SCOPE] [--at ISO8601]
            reprocess
            rebuild-derived
            doctor [--offline]
        TEXT
      end

      private

      def run_command(factory, command, argv, out:, err:)
        case command
        when "sync" then parse_sync(factory, argv, out:, err:)
        when "backfill" then parse_backfill(factory, argv, out:, err:)
        when "report" then parse_report(factory, argv, out:, err:)
        when "reprocess" then parse_offline(factory, command, argv, out:, err:)
        when "rebuild-derived" then parse_offline(factory, command, argv, out:, err:)
        when "doctor" then parse_doctor(factory, argv, out:, err:)
        end
      end

      def parse_sync(factory, argv, out:, err:)
        options = { source: "all" }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: devdash sync [github|linear|slack|all] [--repo SCOPE]"
          opts.on("-h", "--help", "show this help") { }
          opts.on("--repo SCOPE", "repository alias, owner/name, or all") { |value| options[:repository_selector] = value }
        end
        if argv.any? { |argument| %w[-h --help].include?(argument) }
          out.puts parser
          return 0
        end
        parser.parse!(argv)
        options[:source] = argv.shift || "all"
        raise Commands::UsageError, "extra arguments: #{argv.join(" ")}" unless argv.empty?
        factory.call("sync", options.merge(out:, err:))
      end

      def parse_backfill(factory, argv, out:, err:)
        options = {}
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: devdash backfill --days N [--repo SCOPE]"
          opts.on("-h", "--help", "show this help") { }
          opts.on("--days N", Integer, "number of days") { |value| options[:days] = value }
          opts.on("--repo SCOPE", "repository alias, owner/name, or all") { |value| options[:repository_selector] = value }
        end
        if argv.any? { |argument| %w[-h --help].include?(argument) }
          out.puts parser
          return 0
        end
        parser.parse!(argv)
        raise Commands::UsageError, "--days is required" unless options.key?(:days)
        raise Commands::UsageError, "extra arguments: #{argv.join(" ")}" unless argv.empty?
        factory.call("backfill", options.merge(out:, err:))
      end

      def parse_report(factory, argv, out:, err:)
        options = { window: "7d" }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: devdash report --window 7d|30d|180d [--repo SCOPE] [--at ISO8601]"
          opts.on("-h", "--help", "show this help") { }
          opts.on("--window WINDOW", "7d, 30d, or 180d") { |value| options[:window] = value }
          opts.on("--repo SCOPE", "repository alias, owner/name, or all") { |value| options[:repository_selector] = value }
          opts.on("--at ISO8601", "report end timestamp") { |value| options[:at] = value }
        end
        if argv.any? { |argument| %w[-h --help].include?(argument) }
          out.puts parser
          return 0
        end
        parser.parse!(argv)
        raise Commands::UsageError, "extra arguments: #{argv.join(" ")}" unless argv.empty?
        factory.call("report", options.merge(out:, err:))
      end

      def parse_offline(factory, command, argv, out:, err:)
        raise Commands::UsageError, "extra arguments: #{argv.join(" ")}" unless argv.empty?
        factory.call(command, { out:, err: })
      end

      def parse_doctor(factory, argv, out:, err:)
        options = { offline: false }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: devdash doctor [--offline]"
          opts.on("-h", "--help", "show this help") { }
          opts.on("--offline", "skip GitHub, Linear, and Slack access probes") { options[:offline] = true }
        end
        if argv.any? { |argument| %w[-h --help].include?(argument) }
          out.puts parser
          return 0
        end
        parser.parse!(argv)
        raise Commands::UsageError, "extra arguments: #{argv.join(" ")}" unless argv.empty?
        factory.call("doctor", options.merge(out:, err:))
      end

      def default_command(command, options)
        klass = {
          "sync" => Commands::Sync,
          "backfill" => Commands::Backfill,
          "report" => Commands::Report,
          "reprocess" => Commands::Reprocess,
          "rebuild-derived" => Commands::RebuildDerived,
          "doctor" => Commands::Doctor
        }.fetch(command)
        object_options = options.dup
        out = object_options.delete(:out) || $stdout
        err = object_options.delete(:err) || $stderr
        klass.new(out:, err:).call(**object_options)
      end
    end
  end
end
