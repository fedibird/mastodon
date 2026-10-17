# frozen_string_literal: true

require 'rails_helper'

describe TimelineSeek::RedisBulkScore do
  after do
    clients.each do |client|
      client.close if client.respond_to?(:close) && !client.equal?(redis) && !client.equal?(raw_redis)
    end
  end

  let(:clients) { [] }

  it 'reads a namespaced key and a raw key with pipelined ZSCORE, in either order' do
    namespaced = namespaced_redis
    raw = raw_redis
    prefixed = "p4b:namespaced:#{SecureRandom.hex(4)}"
    plain = "p4b:raw:#{SecureRandom.hex(4)}"
    namespaced.zadd(prefixed, 11, 11)
    raw.zadd(plain, 21, 21)
    expect(namespaced).not_to receive(:zmscore)
    expect(raw).not_to receive(:zmscore)

    expect(described_class.new(namespaced).present_ids(prefixed, [11, 12])).to eq([11])
    expect(described_class.new(raw).present_ids(plain, [21, 22])).to eq([21])
    expect(described_class.new(raw).present_ids(prefixed, [11])).to eq([])
    expect(described_class.new(namespaced).present_ids(plain, [21])).to eq([])
  ensure
    namespaced&.del(prefixed) if prefixed
    raw&.del(plain) if plain
  end

  it 'does not keep a strategy after a client is closed' do
    key = "p4b:closed:#{SecureRandom.hex(4)}"
    first = open_redis
    first.zadd(key, 31, 31)
    expect(first).not_to receive(:zmscore)
    expect(described_class.new(first).present_ids(key, [31, 32])).to eq([31])
    first.del(key)
    first.close

    replacement = open_redis
    expect(replacement).not_to receive(:zmscore)
    expect(described_class.new(replacement).present_ids(key, [31])).to eq([])
    expect(described_class.instance_variables).not_to include(:@strategies, :@strategy)
  ensure
    replacement&.del(key) if defined?(replacement) && replacement && key
    replacement&.close if defined?(replacement) && replacement
  end

  def namespaced_redis
    Redis::Namespace.new("p4b#{SecureRandom.hex(4)}", redis: raw_redis)
  end

  def raw_redis
    redis.is_a?(Redis::Namespace) ? redis.redis : redis
  end

  def open_redis
    Redis.new(url: ENV['REDIS_URL'].presence || 'redis://127.0.0.1:6379').tap { |client| clients << client }
  end
end
