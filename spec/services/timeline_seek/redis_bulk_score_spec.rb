# frozen_string_literal: true

require 'rails_helper'

describe TimelineSeek::RedisBulkScore do
  describe '.strategy_from_version' do
    it 'uses ZMSCORE from Redis 6.2 and a pipeline before that' do
      expect(described_class.strategy_from_version('6.0.16')).to eq(:pipeline)
      expect(described_class.strategy_from_version('6.1.0')).to eq(:pipeline)
      expect(described_class.strategy_from_version('6.2.0')).to eq(:zmscore)
      expect(described_class.strategy_from_version('7.2.4')).to eq(:zmscore)
      expect(described_class.strategy_from_version(nil)).to eq(:pipeline)
      expect(described_class.strategy_from_version('unknown')).to eq(:pipeline)
    end

    it 'keeps namespaced connections on pipelined ZSCORE so the prefix is applied' do
      namespaced = namespaced_redis
      described_class.reset_strategy!
      expect(described_class.strategy_for(namespaced)).to eq(:pipeline)
    end
  end

  describe 'per connection' do
    after do
      described_class.reset_strategy!
    end

    it 'does not let the first connection decide the strategy for the next one' do
      namespaced = namespaced_redis
      raw = raw_redis
      other = Redis.new(url: redis_url)

      described_class.reset_strategy!
      expect(described_class.strategy_for(namespaced)).to eq(:pipeline)
      expect(described_class.strategy_for(raw)).to eq(:zmscore)

      described_class.reset_strategy!
      expect(described_class.strategy_for(raw)).to eq(:zmscore)
      expect(described_class.strategy_for(namespaced)).to eq(:pipeline)

      described_class.prefer_pipeline!(raw)
      expect(described_class.strategy_for(raw)).to eq(:pipeline)
      expect(described_class.strategy_for(other)).to eq(:zmscore)
      expect(described_class.strategy_for(namespaced)).to eq(:pipeline)
    ensure
      other&.close
    end

    it 'reads a namespaced key with pipelined ZSCORE and a raw key with ZMSCORE' do
      namespaced = namespaced_redis
      raw = raw_redis
      described_class.reset_strategy!
      expect(described_class.strategy_for(namespaced)).to eq(:pipeline)

      prefixed = "p4b:namespaced:#{SecureRandom.hex(4)}"
      plain = "p4b:raw:#{SecureRandom.hex(4)}"
      namespaced.zadd(prefixed, 11, 11)
      raw.zadd(plain, 21, 21)
      expect(namespaced).not_to receive(:zmscore)

      expect(described_class.new(namespaced).present_ids(prefixed, [11, 12])).to eq([11])
      expect(described_class.strategy_for(raw)).to eq(:zmscore)
      expect(raw).to receive(:zmscore).and_call_original
      expect(described_class.new(raw).present_ids(plain, [21, 22])).to eq([21])
      expect(described_class.new(namespaced).present_ids(plain, [21])).to eq([])
    ensure
      namespaced&.del(prefixed) if prefixed
      raw&.del(plain) if plain
    end
  end

  def namespaced_redis
    Redis::Namespace.new("p4b#{SecureRandom.hex(4)}", redis: raw_redis)
  end

  def raw_redis
    redis.is_a?(Redis::Namespace) ? redis.redis : redis
  end

  def redis_url
    ENV['REDIS_URL'].presence || 'redis://127.0.0.1:6379'
  end
end
