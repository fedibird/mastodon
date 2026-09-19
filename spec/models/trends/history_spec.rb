# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Trends::History do
  let(:prefix) { 'email_domain_blocks' }
  let(:id) { 42 }
  let(:history) { described_class.new(prefix, id) }
  let(:now) { Time.utc(2026, 9, 19, 12, 0, 0) }

  around do |example|
    travel_to(now) { example.run }
  end

  describe '#as_json' do
    it 'serializes seven days' do
      expect(history.as_json.size).to eq 7
    end

    it 'includes day, accounts, and uses as strings' do
      history.as_json.each do |entry|
        expect(entry.keys).to contain_exactly(:day, :accounts, :uses)
        expect(entry[:day]).to be_a(String)
        expect(entry[:accounts]).to be_a(String)
        expect(entry[:uses]).to be_a(String)
      end
    end

    it 'starts empty with zero counts' do
      history.as_json.each do |entry|
        expect(entry[:accounts]).to eq '0'
        expect(entry[:uses]).to eq '0'
      end
    end
  end

  describe '#add' do
    it 'increments uses' do
      history.add('192.0.2.1')

      expect(history.get(now).uses).to eq 1
    end

    it 'counts unique accounts with HyperLogLog semantics' do
      history.add('192.0.2.1')
      history.add('192.0.2.1')

      expect(history.get(now).uses).to eq 2
      expect(history.get(now).accounts).to eq 1

      history.add('192.0.2.2')

      expect(history.get(now).uses).to eq 3
      expect(history.get(now).accounts).to eq 2
    end

    it 'writes Redis keys with the expected prefix' do
      history.add('192.0.2.1')

      day = now.beginning_of_day.to_i
      expect(redis.exists("activity:#{prefix}:#{id}:#{day}")).to eq 1
      expect(redis.exists("activity:#{prefix}:#{id}:#{day}:accounts")).to eq 1
    end

    it 'sets expiry on Redis keys' do
      history.add('192.0.2.1')

      day = now.beginning_of_day.to_i
      expect(redis.ttl("activity:#{prefix}:#{id}:#{day}")).to be_within(5).of(14.days.seconds)
      expect(redis.ttl("activity:#{prefix}:#{id}:#{day}:accounts")).to be_within(5).of(14.days.seconds)
    end
  end

  describe '#aggregate' do
    it 'sums uses and unique accounts across a date range' do
      history.add('192.0.2.1', 1.day.ago)
      history.add('192.0.2.1', now)
      history.add('192.0.2.2', now)

      aggregate = history.aggregate(1.day.ago.to_date..now.to_date)

      expect(aggregate.uses).to eq 3
      expect(aggregate.accounts).to eq 2
    end
  end

  describe '#each' do
    it 'yields seven days' do
      expect(history.each.map(&:day)).to eq((0...7).map { |i| i.days.ago.beginning_of_day })
    end
  end
end
