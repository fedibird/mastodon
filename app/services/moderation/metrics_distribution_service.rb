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
#
# Feature eligibility: a metric that is not applicable to a subject (a zero
# denominator such as no contacts / no followed targets, or no negative signal
# for the continuation metrics) is EXCLUDED from that feature's distribution
# rather than counted as a real 0, so the distribution is not skewed. Each
# summary reports +n+ (the eligible sample) and +excluded_n+; +subject_count+ is
# the whole (de-duplicated) cohort. A genuine 0 from an eligible subject is kept.
module Moderation
  class MetricsDistributionService
    # Scalar behavioural features worth summarising for calibration.
    DEFAULT_FEATURES = %w(
      contacts_total
      unique_targets
      follows
      unique_follow_targets
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

    # Per-feature eligibility: a feature only enters a subject's distribution when
    # the metric is actually applicable, so a "not-applicable 0" (zero denominator
    # / no negative signal) is excluded rather than skewing the distribution as a
    # real 0. Features absent here are always eligible (raw counts). The 0.0/0 of
    # an eligible subject is still counted as a genuine 0.
    ELIGIBILITY = {
      'negative_response_rate'                  => ->(data) { data['unique_targets'].to_i.positive? },
      'linked_negative_rate'                    => ->(data) { data['unique_targets'].to_i.positive? },
      'follow_reject_rate'                      => ->(data) { data['unique_follow_targets'].to_i.positive? },
      'new_targets_after_first_negative_signal' => ->(data) { data['first_negative_signal_at'].present? },
      'follows_after_first_negative_signal'     => ->(data) { data['first_negative_signal_at'].present? },
    }.freeze

    def initialize(metrics_service: Moderation::BehavioralMetricsService.new)
      @metrics_service = metrics_service
    end

    def call(subjects, now: Time.now.utc, windows: Moderation::BehavioralMetricsService::DEFAULT_WINDOWS, features: DEFAULT_FEATURES)
      window_names  = windows.keys + ['lifetime']
      accumulators  = window_names.index_with { features.index_with { { values: [], excluded: 0 } } }
      seen          = Set.new
      subject_count = 0

      subjects.each do |subject|
        # De-dupe by subject id so a repeated input is not double-counted.
        next unless seen.add?(subject.id)

        subject_count += 1
        metrics = @metrics_service.call(subject, now: now, windows: windows)

        window_names.each do |name|
          data = name == 'lifetime' ? metrics['lifetime'] : metrics.dig('windows', name)
          next if data.nil?

          features.each do |feature|
            accumulator = accumulators[name][feature]

            if feature_eligible?(feature, data)
              value = data[feature]
              accumulator[:values] << value if value.is_a?(Numeric)
            else
              accumulator[:excluded] += 1
            end
          end
        end
      end

      {
        'generated_at'  => now.iso8601,
        'subject_count' => subject_count,
        'features'      => features,
        'windows'       => window_names.index_with { |name| features.index_with { |feature| summarize(accumulators[name][feature]) } },
      }
    end

    private

    def feature_eligible?(feature, data)
      rule = ELIGIBILITY[feature]
      rule.nil? || rule.call(data)
    end

    def summarize(accumulator)
      values   = accumulator[:values]
      excluded = accumulator[:excluded]
      return empty_summary(excluded) if values.empty?

      sorted = values.sort
      {
        'n'           => sorted.size,
        'excluded_n'  => excluded,
        'nonzero'     => sorted.count { |value| value != 0 },
        'min'         => sorted.first,
        'max'         => sorted.last,
        'mean'        => sorted.sum.to_f / sorted.size,
        'percentiles' => PERCENTILES.index_with { |p| percentile(sorted, p) },
      }
    end

    def empty_summary(excluded = 0)
      { 'n' => 0, 'excluded_n' => excluded, 'nonzero' => 0, 'min' => nil, 'max' => nil, 'mean' => nil, 'percentiles' => PERCENTILES.index_with { nil } }
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
