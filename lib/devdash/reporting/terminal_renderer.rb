# frozen_string_literal: true

require "time"

module Devdash
  module Reporting
    class TerminalRenderer
      SECTION_TITLES = { "speed" => "SPEED", "ease" => "EASE", "quality" => "QUALITY", "thriving" => "THRIVING" }.freeze
      HEADER = "Metric                         Role        You   Previous   Delta   Peers"

      def render(report)
        scope = value(report, :repository_scope)
        window = value(report, :window)
        previous = value(report, :previous_window)
        lines = []
        lines << "Personal Engineering Dashboard · #{value(window, :key)} · #{value(scope, :label)}"
        lines << "Current: #{timestamp(value(window, :start_at))} → #{timestamp(value(window, :end_at))}"
        lines << "Previous: #{timestamp(value(previous, :start_at))} → #{timestamp(value(previous, :end_at))}"
        lines << ""

        sections = value(report, :sections) || {}
        %w[speed ease quality thriving].each do |section|
          lines << SECTION_TITLES.fetch(section)
          lines << HEADER
          Array(sections[section] || sections[section.to_sym]).each do |metric|
            lines.concat(render_metric(metric))
          end
          lines << ""
        end

        if all_scope?(scope)
          lines.concat(render_repository_summary(sections))
          lines << ""
        end
        lines.concat(render_coverage(report))
        lines.join("\n").sub(/\n+\z/, "") + "\n"
      end

      private

      def render_metric(metric)
        name = value(metric, :name).to_s
        role = value(metric, :signal_role).to_s
        definition_unit = value(metric, :unit)
        current = value(metric, :current) || {}
        previous = value(metric, :previous) || {}
        comparison = value(metric, :comparison) || {}
        current_value = value(current, :value)
        previous_value = value(previous, :value)
        delta = if comparison.key?(:absolute_delta) || comparison.key?("absolute_delta")
          value(comparison, :absolute_delta)
        elsif !current_value.nil? && !previous_value.nil?
          current_value.to_f - previous_value.to_f
        end
        peer_text = peer_summary(comparison, metric)
        line = format("%-30s %-11s %5s %10s %7s   %s", name[0, 30], role[0, 11],
          display_value(current_value, unit: definition_unit), display_value(previous_value, unit: definition_unit),
          display_delta(delta, unit: definition_unit), peer_text)
        lines = [line]
        breakdown = value(metric, :breakdown) || value(current, :breakdown) || {}
        lines.concat(render_metric_breakdown(breakdown)) if all_scope_metric?(breakdown)
        if value(current, :weekday_rate)
          lines << "  weekday-equivalent: #{display_value(value(current, :weekday_rate), unit: nil)} per weekday"
        end
        if value(metric, :value_type).to_s == "duration"
          p75 = value(breakdown, :p75)
          p75 ||= Metrics::Statistics.quantile(value(breakdown, :samples), 0.75) if value(breakdown, :samples)
          lines << "  p75: #{display_value(p75, unit: definition_unit)}" if p75
        end
        lines << "  coverage: #{coverage_text(value(metric, :coverage))}" if value(metric, :coverage)
        lines
      end

      def peer_summary(comparison, metric)
        statistics = value(comparison, :statistics) || {}
        n = value(statistics, :n)
        if n && n.to_i < 3
          return "insufficient peer sample (n=#{n})"
        end
        median = display_value(value(statistics, :median), unit: value(metric, :unit))
        return "—" if median == "—"

        iqr = value(statistics, :iqr)
        suffix = iqr.nil? ? "n=#{n}" : "IQR #{display_value(iqr, unit: value(metric, :unit))} · n=#{n}"
        "median #{median} · #{suffix}"
      end

      def render_metric_breakdown(breakdown)
        repositories = value(breakdown, :repositories) || value(breakdown, :repository_values)
        lines = Array(repositories).map do |name, result|
          "  #{name}: #{display_value(result, unit: nil)}"
        end
        multi = value(breakdown, :multi_repo)
        unmapped = value(breakdown, :unmapped)
        lines << "  multi-repo: #{multi}" unless multi.nil?
        lines << "  unmapped: #{unmapped}" unless unmapped.nil?
        lines
      end

      def render_repository_summary(sections)
        lines = ["REPOSITORY BREAKDOWN"]
        seen = {}
        sections.each_value do |metrics|
          Array(metrics).each do |metric|
            breakdown = value(metric, :breakdown) || {}
            repositories = value(breakdown, :repositories) || value(breakdown, :repository_values) || {}
            Array(repositories).each_key { |name| seen[name] = true }
          end
        end
        seen.keys.sort.each { |name| lines << "  #{name}" }
        lines << "  multi-repo / unmapped Linear attribution is retained in metric rows"
        lines
      end

      def render_coverage(report)
        lines = ["COVERAGE"]
        reasons = Array(value(report, :partial_data_reasons))
        lines << "  partial data: #{reasons.join('; ')}" unless reasons.empty?
        freshness = value(report, :freshness) || {}
        freshness.keys.sort.each do |metric|
          timestamps = Array(freshness[metric] || freshness[metric.to_sym])
          latest = timestamps.map { |_key, stamp| stamp }.compact.max_by(&:to_s)
          lines << "  #{metric}: #{latest ? "fresh through #{timestamp(latest)}" : "freshness unavailable"}"
        end

        lines << "FRAMEWORK COVERAGE"
        frameworks = value(report, :framework_coverage) || {}
        %w[space devex dora thriving].each do |framework|
          item = frameworks[framework] || frameworks[framework.to_sym] || {}
          status = value(item, :status).to_s
          reason = value(item, :reason)
          label = framework == "devex" ? "DevEx" : (framework == "thriving" ? "Thriving" : framework.upcase)
          if reason
            lines << "  #{label}: #{reason}"
          else
            lines << "  #{label}: #{status.empty? ? "unavailable" : status}"
            dimensions = value(item, :dimensions) || {}
            dimensions.keys.sort.each do |dimension|
              detail = dimensions[dimension] || dimensions[dimension.to_sym]
              proxy = value(detail, :proxy) ? " (proxy)" : ""
              lines << "    #{dimension}: #{value(detail, :status)}#{proxy}"
            end
          end
        end
        lines
      end

      def coverage_text(coverage)
        status = value(coverage, :status).to_s
        return "unavailable" if status.empty?

        text = status
        reasons = Array(value(coverage, :reasons))
        text += " (#{reasons.first})" if status == "partial" && reasons.first
        text
      end

      def display_value(value, unit: nil)
        return "—" if value.nil?
        return value.to_s if value.is_a?(String) && unit.nil?

        number = round_number(value)
        case unit.to_s
        when "hours" then "#{number}h"
        when "minutes" then "#{number}m"
        when "days" then "#{number}d"
        when "percent" then "#{number}%"
        else number.to_s
        end
      end

      def display_delta(value, unit: nil)
        return "—" if value.nil?

        number = round_number(value)
        sign = number.to_f.positive? ? "+" : ""
        "#{sign}#{display_value(number, unit: unit)}"
      end

      def round_number(value)
        number = value.to_f
        rounded = number.round(1)
        rounded.to_i == rounded ? rounded.to_i : rounded
      end

      def timestamp(value)
        return "—" unless value
        return value.utc.strftime("%Y-%m-%d %H:%MZ") if value.respond_to?(:utc)

        Time.iso8601(value.to_s).utc.strftime("%Y-%m-%d %H:%MZ")
      rescue ArgumentError
        value.to_s
      end

      def all_scope?(scope)
        value(scope, :key).to_s == "all"
      end

      def all_scope_metric?(breakdown)
        repositories = value(breakdown, :repositories) || value(breakdown, :repository_values)
        (repositories && !Array(repositories).empty?) || !value(breakdown, :multi_repo).nil? || !value(breakdown, :unmapped).nil?
      end

      def value(object, key)
        return nil if object.nil?
        return object.public_send(key) if object.respond_to?(key)
        return object[key] if object.respond_to?(:key?) && object.key?(key)
        return object[key.to_s] if object.respond_to?(:key?) && object.key?(key.to_s)

        nil
      end
    end
  end
end
