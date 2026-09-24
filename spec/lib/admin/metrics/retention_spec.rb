# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Retention do
  def cohort_values(retention)
    retention.cohorts.map do |cohort|
      [cohort.period, cohort.data.map { |point| [point.date, point.value, point.rate] }]
    end
  end

  it 'keeps a user with no sign-in in the cohort but not in retained users' do
    Fabricate(:user, created_at: Time.utc(2026, 9, 1, 8, 0, 0), current_sign_in_at: Time.utc(2026, 9, 1, 9, 0, 0))
    Fabricate(:user, created_at: Time.utc(2026, 9, 1, 10, 0, 0), current_sign_in_at: nil)

    retention = described_class.new(Date.new(2026, 9, 1), Date.new(2026, 9, 1), 'day')

    expect(cohort_values(retention)).to eq [
      [Date.new(2026, 9, 1), [[Date.new(2026, 9, 1), '1', 0.5]]],
    ]
  end

  it 'groups monthly cohorts by the latest sign-in month' do
    Fabricate(:user, created_at: Time.utc(2026, 9, 1, 8, 0, 0), current_sign_in_at: Time.utc(2026, 10, 15, 8, 0, 0))
    Fabricate(:user, created_at: Time.utc(2026, 9, 15, 8, 0, 0), current_sign_in_at: Time.utc(2026, 9, 20, 8, 0, 0))

    retention = described_class.new(Date.new(2026, 9, 1), Date.new(2026, 10, 31), 'month')

    expect(cohort_values(retention)).to eq [
      [Date.new(2026, 9, 1), [
        [Date.new(2026, 9, 1), '2', 1.0],
        [Date.new(2026, 10, 1), '1', 0.5],
      ]],
      [Date.new(2026, 10, 1), [
        [Date.new(2026, 10, 1), '0', 0.0],
      ]],
    ]
  end

  it 'uses day when frequency is nil' do
    retention = described_class.new(Date.new(2026, 9, 1), Date.new(2026, 9, 1), nil)
    expect(retention.cohorts.first.frequency).to eq 'day'
  end

  it 'returns zero without raising when a cohort has no new users' do
    retention = described_class.new(Date.new(2026, 9, 1), Date.new(2026, 9, 2), 'day')

    expect { retention.cohorts }.not_to raise_error
    expect(cohort_values(retention)).to eq [
      [Date.new(2026, 9, 1), [
        [Date.new(2026, 9, 1), '0', 0.0],
        [Date.new(2026, 9, 2), '0', 0.0],
      ]],
      [Date.new(2026, 9, 2), [
        [Date.new(2026, 9, 2), '0', 0.0],
      ]],
    ]
  end

  it 'caches a frequency separately from another frequency' do
    Fabricate(:user, created_at: Time.utc(2026, 9, 1, 8, 0, 0), current_sign_in_at: Time.utc(2026, 9, 1, 9, 0, 0))
    retention = described_class.new(Date.new(2026, 9, 1), Date.new(2026, 9, 1), 'day')
    expect(retention.cohorts.first.data.first.value).to eq '1'

    Fabricate(:user, created_at: Time.utc(2026, 9, 1, 11, 0, 0), current_sign_in_at: Time.utc(2026, 9, 1, 11, 0, 0))
    cached = described_class.new(Date.new(2026, 9, 1), Date.new(2026, 9, 1), 'day')
    expect(cached.cohorts.first.data.first.value).to eq '1'

    monthly = described_class.new(Date.new(2026, 9, 1), Date.new(2026, 9, 1), 'month')
    expect(monthly.cohorts.first.data.first.value).to eq '2'
  end
end
