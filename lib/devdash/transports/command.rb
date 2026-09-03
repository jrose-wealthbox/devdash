# frozen_string_literal: true

require "open3"
require_relative "errors"

module Devdash
  module Transports
    class Command
      Result = Data.define(:stdout, :stderr, :exitstatus)
      SECRET_PATTERN = /(?:authorization|access_token|api[_-]?key|x-api-key|token)/i

      def initialize(runner: nil)
        @runner = runner || ->(env, executable, *arguments, stdin_data:) {
          Open3.capture3(env, executable, *arguments, stdin_data: stdin_data)
        }
      end

      def capture(*argv, env: {})
        raise ArgumentError, "command executable is required" if argv.empty?

        stdout, stderr, status = @runner.call(env.transform_keys(&:to_s), *argv.map(&:to_s), stdin_data: "")
        result = Result.new(stdout, stderr, status.exitstatus)
        return result if status.success?

        raise CommandError, "#{argv.first} failed with exit status #{status.exitstatus}: #{sanitize(stderr)}"
      end

      private

      def sanitize(message)
        message.to_s.gsub(/(#{SECRET_PATTERN.source})(?:\s*[:=]\s*|\s+)(?:Bearer\s+)?[^\s,]+/i, "\\1=[REDACTED]")
      end
    end
  end
end
