# frozen_string_literal: true

module Admin::ModerationMetricsHelper
  # Rows rendered in the windowed metrics table, grouped by section. Each entry
  # is [i18n_key, metric_key, kind]. `kind` drives formatting only.
  METRIC_ROWS = {
    'contact' => [
      %w(contacts_total contacts_total count),
      %w(unique_targets unique_targets count),
      %w(follows follows count),
    ],
    'rejections' => [
      %w(rejections_received_total rejections_received_total count),
      %w(blocks_received blocks_received count),
      %w(follow_rejects_received follow_rejects_received count),
      %w(remove_follower_received remove_follower_received count),
      %w(reports_received reports_received count),
      %w(mutes_received mutes_received count),
    ],
    'responders' => [
      %w(unique_negative_responders unique_negative_responders count),
      %w(linked_negative_responders linked_negative_responders count),
      %w(correlated_negative_responders correlated_negative_responders count),
    ],
    'rates' => [
      %w(negative_response_rate negative_response_rate rate),
      %w(linked_negative_rate linked_negative_rate rate),
      %w(follow_reject_rate follow_reject_rate rate),
    ],
    'continuation' => [
      %w(first_negative_signal_at first_negative_signal_at time),
      %w(new_targets_after_first_negative_signal new_targets_after_first_negative_signal count),
      %w(follows_after_first_negative_signal follows_after_first_negative_signal count),
    ],
  }.freeze

  # Ordered [label, window_hash] pairs: the configured windows then lifetime.
  def moderation_metric_columns(metrics)
    columns = (metrics['windows'] || {}).map { |name, data| [name, data] }
    columns << [t('admin.moderation_metrics.lifetime'), metrics['lifetime']] if metrics['lifetime']
    columns
  end

  # Present a raw metric value for display. Rates (raw 0..1 floats from the
  # analysis layer) are rounded here for the UI; counts stay integers; times are
  # localized.
  def format_moderation_metric(value, kind)
    case kind
    when 'rate'
      value.nil? ? '—' : number_to_percentage(value.to_f * 100, precision: 1)
    when 'time'
      value.present? ? l(Time.iso8601(value)) : '—'
    else
      number_with_delimiter(value.to_i)
    end
  end
end
