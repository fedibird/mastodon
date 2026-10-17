# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Feed, type: :model do
  def query_count(&block)
    count = 0
    callback = lambda do |*, payload|
      sql = payload[:sql]
      next if payload[:name] == 'SCHEMA' || sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)

      count += 1
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    count
  end

  let(:account) { Fabricate(:account) }

  subject { HomeFeed.new(account) }

  describe 'scanning past redis ids missing from the database' do
    it 'returns the next older page when the newest redis ids are gone' do
      (301..330).each do |id|
        Fabricate(:status, account: account, id: id)
      end
      redis.zadd(FeedManager.instance.key(:home, account.id), (301..350).map { |id| [id, id] })

      expect(subject.get(20, 351).map(&:id)).to eq(330.downto(311).to_a)
    end

    it 'keeps the common page to one lookup and widens the scan after misses' do
      (401..420).each { |id| Fabricate(:status, account: account, id: id) }
      redis.zadd(FeedManager.instance.key(:home, account.id), (401..420).map { |id| [id, id] })

      ready = query_count { subject.get(20) }

      redis.del(FeedManager.instance.key(:home, account.id))
      redis.zadd(FeedManager.instance.key(:home, account.id), (201..420).map { |id| [id, id] })

      sparse = query_count { subject.get(20) }

      expect(ready).to be <= 3
      expect(sparse).to be < 12
      expect(subject.get(20).map(&:id)).to eq(420.downto(401).to_a)
    end

    it 'returns the next newer page when ids above min_id are gone' do
      (341..360).each do |id|
        Fabricate(:status, account: account, id: id)
      end
      redis.zadd(FeedManager.instance.key(:home, account.id), (321..360).map { |id| [id, id] })

      expect(subject.get(20, nil, nil, 320).map(&:id)).to eq(360.downto(341).to_a)
    end
  end
end
