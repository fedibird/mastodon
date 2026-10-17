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
      skip 'REDIS_NAMESPACE is unset' unless redis.is_a?(Redis::Namespace)

      described_class.reset_strategy!
      expect(described_class.strategy_for(redis)).to eq(:pipeline)
    end
  end
end
