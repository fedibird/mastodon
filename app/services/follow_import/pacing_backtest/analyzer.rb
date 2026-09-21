# frozen_string_literal: true

# Orchestrates CSV load, scenario validation, replays, and report files.
module FollowImport
  class PacingBacktest
    class Analyzer
      def initialize(paths)
        @paths = symbolize(paths)
        @now = @paths[:now] || Time.now.utc
      end

      def run
        scenarios = Scenario.load(@paths[:scenarios])
        dataset = Input.load(**@paths)
        baseline = Baseline.new(dataset, scenarios.bucket_seconds).to_h
        tick_summary = TickSummary.new(dataset.ticks).to_h
        scenario_results = scenarios.candidates.map do |candidate|
          replay_scenario(candidate, dataset, scenarios.bucket_seconds, tick_summary)
        end

        result = {
          'schema' => FollowImport::PacingBacktest::SCHEMA_NAME,
          'schema_version' => FollowImport::PacingBacktest::SCHEMA_VERSION,
          'generated_at' => @now.utc.iso8601(6),
          'input_files' => dataset.input_files,
          'observation_window' => {
            'min_event_time' => baseline.dig('dataset', 'min_event_time'),
            'max_event_time' => baseline.dig('dataset', 'max_event_time'),
            'duration_seconds' => baseline.dig('dataset', 'duration_seconds'),
          },
          'warnings' => warnings(dataset),
          'baseline' => baseline,
          'scheduler_ticks' => tick_summary,
          'scenarios' => scenario_results,
        }
        Report.new(result).write(@paths)
        result
      end

      private

      def replay_scenario(candidate, dataset, bucket_seconds, tick_summary)
        rows = dataset.timed_rows
        pressure = FixedPressureReplay.new(rows, candidate.fixed_profile, bucket_seconds)
        {
          'name' => candidate.name,
          'global_budget' => candidate.global_budget,
          'fixed_profile' => candidate.fixed_profile.identity.merge(
            'digest' => candidate.fixed_profile.digest
          ),
          'adaptive_profile' => adaptive_identity(candidate),
          'fixed_cap_pressure' => {
            'first_attempt' => pressure.first_attempt,
            'all_attempt' => pressure.all_attempt.merge(
              'note' => FollowImport::PacingBacktest::ALL_ATTEMPT_NOTE
            ),
          },
          'suppression' => SuppressionReplay.new(rows, candidate.fixed_profile).to_h,
          'adaptive' => AdaptiveReplay.new(rows, candidate, bucket_seconds).to_h,
          'global_budget_envelope' => GlobalEnvelope.new(dataset.dispatch_passes, candidate.global_budget, bucket_seconds).to_h,
          'scheduler_ticks' => tick_summary,
          'limitations' => [
            FollowImport::PacingBacktest::CAUSAL_WARNING,
            FollowImport::PacingBacktest::RIGHT_CENSOR_WARNING,
            FollowImport::PacingBacktest::CPU_DB_WARNING,
            FollowImport::PacingBacktest::MODERATION_WARNING,
          ],
        }
      end

      def adaptive_identity(candidate)
        return { 'available' => false } unless candidate.adaptive?

        candidate.adaptive_profile.identity.merge('available' => true)
      end

      def warnings(dataset)
        list = [
          FollowImport::PacingBacktest::CAUSAL_WARNING,
          FollowImport::PacingBacktest::RIGHT_CENSOR_WARNING,
          FollowImport::PacingBacktest::CPU_DB_WARNING,
          FollowImport::PacingBacktest::MODERATION_WARNING,
          FollowImport::PacingBacktest::ALL_ATTEMPT_NOTE,
          FollowImport::PacingBacktest::NO_REFLOW_NOTE,
        ]
        list.concat(dataset.warnings)
        list
      end

      def symbolize(paths)
        paths.to_h.transform_keys(&:to_sym)
      end
    end
  end
end
