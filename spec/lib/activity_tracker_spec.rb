# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityTracker do
  describe '#add' do
    it 'stores a basic counter on the daily key' do
      at_time = Time.utc(2026, 9, 21, 15, 0, 0)
      tracker = described_class.new('test:activity', :basic)

      tracker.add(3, at_time)

      expect(redis.get("test:activity:#{at_time.beginning_of_day.to_i}")).to eq '3'
    end

    it 'counts a repeated unique value once for that day' do
      at_time = Time.utc(2026, 9, 21, 15, 0, 0)
      tracker = described_class.new('test:users', :unique)

      tracker.add(42, at_time)
      tracker.add(42, at_time)

      expect(tracker.sum(at_time.beginning_of_day, at_time.beginning_of_day + 1.day)).to eq 1
    end
  end

  describe '#get' do
    it 'returns a daily series including days with no activity' do
      tracker = described_class.new('test:activity', :basic)
      start_at = Time.utc(2026, 9, 21)
      tracker.add(4, Time.utc(2026, 9, 21, 9, 0, 0))
      tracker.add(2, Time.utc(2026, 9, 23, 9, 0, 0))

      expect(tracker.get(start_at, Time.utc(2026, 9, 24))).to eq [
        [Date.new(2026, 9, 21), 4],
        [Date.new(2026, 9, 22), 0],
        [Date.new(2026, 9, 23), 2],
      ]
    end
  end

  describe '#sum' do
    it 'totals daily basic keys in the range' do
      tracker = described_class.new('test:activity', :basic)
      tracker.add(4, Time.utc(2026, 9, 21, 9, 0, 0))
      tracker.add(6, Time.utc(2026, 9, 22, 9, 0, 0))

      expect(tracker.sum(Time.utc(2026, 9, 21), Time.utc(2026, 9, 23))).to eq 10
    end

    it 'reads a legacy weekly key' do
      at_time = Time.utc(2026, 9, 21, 9, 0, 0)
      redis.set("test:activity:#{at_time.to_date.cweek}", 9)
      tracker = described_class.new('test:activity', :basic)

      expect(tracker.sum(at_time.beginning_of_day, at_time.beginning_of_day + 1.day)).to eq 9
    end
  end

  describe 'class methods' do
    it 'records new activity on daily keys' do
      travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
        described_class.increment('test:interactions')
        described_class.record('test:logins', 7)

        day = Time.utc(2026, 9, 21).beginning_of_day.to_i
        expect(redis.get("test:interactions:#{day}")).to eq '1'
        expect(redis.pfcount("test:logins:#{day}")).to eq 1
        expect(redis.get("test:interactions:#{Date.new(2026, 9, 21).cweek}")).to be_nil
      end
    end
  end
end
