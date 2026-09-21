# frozen_string_literal: true

require 'json'

# Canonical JSON plus a concise Markdown comparison. Markdown never
# ranks a winner or recommends a production profile.
module FollowImport
  class PacingBacktest
    class Report
      FORBIDDEN = /\b(best|recommended|winner|winning|score)\b/i.freeze

      def initialize(result)
        @result = result
      end

      def write(paths)
        write_json(paths[:out_json]) if paths[:out_json].to_s.strip.present?
        write_markdown(paths[:out_md]) if paths[:out_md].to_s.strip.present?
      end

      def markdown
        lines = []
        lines << '# Follow Import pacing backtest'
        lines << ''
        lines << "Schema `#{@result['schema']}` version #{@result['schema_version']}."
        lines << "Generated at #{@result['generated_at']}."
        lines << ''
        lines << '## Warnings'
        Array(@result['warnings']).each { |warning| lines << "- #{warning}" }
        lines << ''
        lines << '## Observation window'
        window = @result['observation_window'] || {}
        lines << "- min: #{window['min_event_time']}"
        lines << "- max: #{window['max_event_time']}"
        lines << "- duration_seconds: #{window['duration_seconds']}"
        lines << ''
        lines << '## Baseline'
        firsts = @result.dig('baseline', 'first_attempts') || {}
        retries = @result.dig('baseline', 'retry_amplification') || {}
        lines << "- unique targets with attempt identity: #{firsts['unique_target_count']}"
        lines << "- first-attempt success count: #{firsts['success_count']}"
        lines << "- later_success_observed_within_window: #{retries['later_success_observed_within_window']}"
        lines << "- no_later_success_observed_within_window: #{retries['no_later_success_observed_within_window']}"
        lines << "- #{retries['right_censoring_note']}"
        lines << ''
        lines << '## Scenario comparison'
        lines << ''
        lines << '| Scenario | First attempts above fixed caps | Successful first attempts above caps | 429/Retry-After window attempts | Adaptive min-cap exposure | Legacy buckets above global budget |'
        lines << '|---|---:|---:|---:|---:|---:|'
        Array(@result['scenarios']).each do |scenario|
          lines << scenario_row(scenario)
        end
        lines << ''
        lines << 'This table is observational. It does not rank candidates and it does not select a production profile.'
        lines << ''
        text = lines.join("\n")
        raise FollowImport::PacingBacktest::Error, 'markdown contained forbidden ranking language' if FORBIDDEN.match?(text)

        text
      end

      def json_text
        "#{JSON.pretty_generate(@result)}\n"
      end

      private

      def write_json(path)
        File.write(path, json_text)
      end

      def write_markdown(path)
        File.write(path, markdown)
      end

      def scenario_row(scenario)
        first = scenario.dig('fixed_cap_pressure', 'first_attempt') || {}
        suppression = scenario['suppression'] || {}
        adaptive = scenario['adaptive'] || {}
        envelope = scenario['global_budget_envelope'] || {}
        window_attempts = suppression['attempts_in_retry_after_window'].to_i + suppression['attempts_in_recent_429_window'].to_i
        min_cap = adaptive['available'] ? adaptive.dig('destination', 'fraction_at_min_cap') : 'unavailable'
        buckets_above = if envelope['available']
                          envelope['fraction_of_active_buckets_above_budget']
                        else
                          'unavailable'
                        end
        [
          '',
          scenario['name'],
          first['above_either_cap'],
          first['successful_above_either_cap'],
          window_attempts,
          min_cap,
          buckets_above,
          '',
        ].join(' | ').strip
      end
    end
  end
end
