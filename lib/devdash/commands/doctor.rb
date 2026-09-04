# frozen_string_literal: true

module Devdash
  module Commands
    class Doctor < Base
      def initialize(configuration: nil, out: $stdout, err: $stderr, database: Devdash::Database,
                     clock: -> { Time.now.utc }, doctor: nil, offline: false)
        super(configuration:, out:, err:, database:, clock:)
        @doctor = doctor
        @offline = offline
      end

      def call(offline: @offline)
        result = (@doctor || build_doctor).call
        result.checks.each do |check|
          out.puts format("%-18s %-10s %-8s %s", check.key, check.status, check.severity, check.message)
          out.puts "  remediation: #{check.remediation}" unless check.remediation.to_s.empty? || check.status == "ok"
        end
        result.exit_status
      end

      private

      def build_doctor
        Devdash::Doctor.new(configuration:, offline:, clock:)
      end
    end
  end
end
