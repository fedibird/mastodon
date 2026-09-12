# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ModerationMetricsHelper, type: :helper do
  describe '#moderation_metric_columns' do
    it 'lists the windows in order and appends lifetime' do
      metrics = { 'windows' => { '1h' => { 'contacts_total' => 1 }, '24h' => { 'contacts_total' => 2 } }, 'lifetime' => { 'contacts_total' => 3 } }

      labels = helper.moderation_metric_columns(metrics).map(&:first)

      expect(labels).to eq ['1h', '24h', I18n.t('admin.moderation_metrics.lifetime')]
    end
  end

  describe '#format_moderation_metric' do
    it 'renders a raw-float rate as a rounded percentage' do
      expect(helper.format_moderation_metric(1.0 / 3, 'rate')).to eq '33.3%'
      expect(helper.format_moderation_metric(nil, 'rate')).to eq '—'
    end

    it 'renders counts as delimited integers' do
      expect(helper.format_moderation_metric(1234, 'count')).to eq '1,234'
    end

    it 'renders an ISO time as a localized time and blank as a dash' do
      time = Time.now.utc.iso8601
      expect(helper.format_moderation_metric(time, 'time')).to eq I18n.l(Time.iso8601(time))
      expect(helper.format_moderation_metric(nil, 'time')).to eq '—'
    end
  end
end
