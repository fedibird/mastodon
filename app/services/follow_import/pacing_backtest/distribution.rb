# frozen_string_literal: true

# Deterministic nearest-rank percentiles.
#
# For a sorted sample of length n and percent p in 0..100:
#   p <= 0  -> first value
#   p >= 100 -> last value
#   otherwise rank = ceil(p/100 * n) (1-indexed), value at rank.
#
# Empty input is unavailable (nils), never a synthetic zero.
module FollowImport
  class PacingBacktest
    module Distribution
      module_function

      def percentile(values, percent)
        return if values.blank?

        sorted = values.sort
        return sorted.first if percent <= 0
        return sorted.last if percent >= 100

        rank = ((percent / 100.0) * sorted.length).ceil
        sorted[rank - 1]
      end

      def summary(values)
        if values.blank?
          return {
            'available' => false,
            'count' => nil,
            'min' => nil,
            'p50' => nil,
            'p90' => nil,
            'p95' => nil,
            'p99' => nil,
            'max' => nil,
            'percentile_method' => FollowImport::PacingBacktest::PERCENTILE_METHOD,
          }
        end

        sorted = values.sort
        {
          'available' => true,
          'count' => sorted.length,
          'min' => sorted.first,
          'p50' => percentile(sorted, 50),
          'p90' => percentile(sorted, 90),
          'p95' => percentile(sorted, 95),
          'p99' => percentile(sorted, 99),
          'max' => sorted.last,
          'percentile_method' => FollowImport::PacingBacktest::PERCENTILE_METHOD,
        }
      end

      def ratio(numerator, denominator)
        return if numerator.nil? || denominator.nil? || denominator.to_f.zero?

        (numerator.to_f / denominator.to_f).round(6)
      end
    end
  end
end
