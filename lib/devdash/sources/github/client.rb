# frozen_string_literal: true

require "json"
require "time"

module Devdash
  class Error < StandardError; end unless const_defined?(:Error, false)
end

require_relative "../../transports/command"

module Devdash
  module Sources
    module Github
      class Client
        attr_reader :page_count

        def initialize(command: Devdash::Transports::Command.new)
          @command = command
          @page_count = 0
        end

        def reset_page_count!
          @page_count = 0
        end

        def repository(name) = get(["gh", "api", "repos/#{name}"])

        def updated_pull_numbers(name, from:, to:)
          search_updated(name, from.utc, to.utc).uniq
        end

        def open_pull_numbers(name)
          paginate(["gh", "api", "-X", "GET", "--paginate", "--slurp", "repos/#{name}/pulls", "-f", "state=open", "-f", "per_page=100"])
            .flat_map { |page| Array(page) }.map { |pull| pull.fetch("number") }.uniq
        end

        def pull(name, number) = get(["gh", "api", "repos/#{name}/pulls/#{number}"])

        def reviews(name, number)
          paginate(["gh", "api", "-X", "GET", "--paginate", "--slurp", "repos/#{name}/pulls/#{number}/reviews", "-f", "per_page=100"]).flat_map { |page| Array(page) }
        end

        def timeline(name, number)
          paginate(["gh", "api", "-X", "GET", "--paginate", "--slurp", "repos/#{name}/issues/#{number}/timeline", "-H", "Accept: application/vnd.github+json", "-f", "per_page=100"]).flat_map { |page| Array(page) }
        end

        def pull_files(name, number)
          paginate(["gh", "api", "-X", "GET", "--paginate", "--slurp", "repos/#{name}/pulls/#{number}/files", "-f", "per_page=100"]).flat_map { |page| Array(page) }
        end

        def default_branch_commits(name, branch:, since:)
          paginate(["gh", "api", "-X", "GET", "--paginate", "--slurp", "repos/#{name}/commits", "-f", "sha=#{branch}", "-f", "since=#{since.utc.iso8601}", "-f", "per_page=100"]).flat_map { |page| Array(page) }
        end

        def commit_detail(name, sha) = get(["gh", "api", "repos/#{name}/commits/#{sha}"])

        private

        def search_updated(name, from, to)
          query = "repo:#{name} is:pr updated:#{from.iso8601}..#{to.iso8601}"
          pages = paginate(["gh", "api", "-X", "GET", "--paginate", "--slurp", "search/issues", "-f", "q=#{query}", "-f", "per_page=100"])
          response = pages.find { |page| page.is_a?(Hash) } || {}
          total = response.fetch("total_count", 0).to_i
          if total > 900
            raise Devdash::Error, "GitHub search range exceeds 1000 results at one-second precision" if to - from <= 1
            middle = from + ((to - from) / 2.0)
            return search_updated(name, from, middle) + search_updated(name, middle, to)
          end
          pages.flat_map { |page| page.is_a?(Hash) ? Array(page["items"]) : [] }.map { |item| item.fetch("number") }
        end

        def get(argv)
          JSON.parse(@command.capture(*argv).stdout)
        end

        def paginate(argv)
          value = JSON.parse(@command.capture(*argv).stdout)
          pages = if value.is_a?(Array)
            if value.empty?
              [[]]
            elsif value.all? { |page| page.is_a?(Array) || (page.is_a?(Hash) && page.key?("items")) }
              value
            else
              [value]
            end
          else
            [value]
          end
          @page_count += pages.length
          pages
        end
      end
    end
  end
end

Devdash::Sources::GitHub = Devdash::Sources::Github unless Devdash::Sources.const_defined?(:GitHub, false)
