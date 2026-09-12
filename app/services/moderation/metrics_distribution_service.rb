# frozen_string_literal: true

# Aggregates Moderation::BehavioralMetricsService output across a set of subjects
# into per-window, per-feature distribution summaries (n, nonzero, min, max,
# mean, percentiles). This is the Observation / Calibration read layer: it lets
# an operator inspect how a feature is distributed across a chosen cohort so that
# sensible thresholds can be reasoned about later.
#
# Strictly observational and read-only:
#
#   * It never writes to the database (it only reads via BehavioralMetricsService,
#     which itself is read-only).
#   * No scoring, thresholds, labels, recommendations, or enforcement — it reports
#     distributions only.
#   * It does NOT scan the whole population on its own: the caller passes the
#     subject set (e.g. a sample, or a hand-labelled cohort such as "known
#     legitimate high-volume users" vs "known problematic"), so distributions can
#     be compared across cohorts without this service inventing labels.
module Moderation
  class MetricsDistributionService
    # Scalar behavioural features worth summarising for calibration.
    DEFAULT_FEATURES = %w(
      contacts_total
      unique_targets
      follows
      rejections_received_total
      unique_negative_responders
      linked_negative_responders
      correlated_negative_responders
      negative_response_rate
      linked_negative_rate
      follow_reject_rate
      new_targets_after_first_negative_signal
      follows_after_first_negative_signal
    ).freeze

    PERCENTILES = [10, 25, 50, 75, 90, 95, 99].freeze

    def initialize(metrics_service: Moderation::BehavioralMetricsService.new)
      @metrics_service = metrics_service
    end

    def call(subjects, now: Time.now.utc, windows: Moderation::BehavioralMetricsService::DEFAULT_WINDOWS, features: DEFAULT_FEATURES)
      window_names = windows.keys + ['lifetime']
      collected    = window_names.index_with { |name| features.index_with { [] } }
      subject_count = 0

      subjects.each do |subject|
        subject_count += 1
        metrics = @metrics_service.call(subject, now: now, windows: windows)

        window_names.each do |name|
          data = name == 'lifetime' ? metrics['lifetime'] : metrics.dig('windows', name)
          next if data.nil?

          features.each do |feature|
            value = data[feature]
            collected[name][feature] << value if value.is_a?(Numeric)
          end
        end
      end

      {
        'generated_at'  => now.iso8601,
        'subject_count' => subject_count,
        'features'      => features,
        'windows'       => window_names.index_with { |name| features.index_with { |feature| summarize(collected[name][feature]) } },
      }
    end

    private

    def summarize(values)
      return empty_summary if values.empty?

      sorted = values.sort
      {
        'n'           => sorted.size,
        'nonzero'     => sorted.count { |value| value != 0 },
        'min'         => sorted.first,
        'max'         => sorted.last,
        'mean'        => sorted.sum.to_f / sorted.size,
        'percentiles' => PERCENTILES.index_with { |p| percentile(sorted, p) },
      }
    end

    def empty_summary
      { 'n' => 0, 'nonzero' => 0, 'min' => nil, 'max' => nil, 'mean' => nil, 'percentiles' => PERCENTILES.index_with { nil } }
    end

    # Linear-interpolated percentile over an already-sorted array (numpy-style
    # "linear" method: rank = p/100 * (n - 1)).
    def percentile(sorted, percent)
      return sorted.first.to_f if sorted.size == 1

      rank  = (percent / 100.0) * (sorted.size - 1)
      lower = rank.floor
      upper = rank.ceil
      return sorted[lower].to_f if lower == upper

      weight = rank - lower
      (sorted[lower] * (1 - weight)) + (sorted[upper] * weight)
    end
  end
end
