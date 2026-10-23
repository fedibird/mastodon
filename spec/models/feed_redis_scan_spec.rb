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

    it 'pages ordinary ids that share one Redis score without dropping members' do
      # 2^53 + 5, +6 and +7 collapse to one double. Exclusive score bounds skip
      # the rest of that bucket; the integer member id must not.
      base = 9_007_199_254_740_992
      bucket = [base + 3, base + 4, base + 5]
      expect(bucket.map(&:to_f).uniq.size).to eq 1
      bucket.each { |id| Fabricate(:status, account: account, id: id, visibility: :public) }
      redis.zadd(FeedManager.instance.key(:home, account.id), bucket.map { |id| [id, id] })

      seen = []
      cursor = nil
      3.times do
        page = subject.get(1, cursor)
        expect(page.size).to eq 1
        seen << page.first.id
        cursor = page.first.id
      end

      expect(seen).to eq bucket.sort.reverse
      expect(subject.get(1, seen.last)).to eq []
    end

    it 'returns the ordinary neighbour when max_id is the next unrepresentable id' do
      base = 9_007_199_254_740_992
      Fabricate(:status, account: account, id: base, visibility: :public)
      redis.zadd(FeedManager.instance.key(:home, account.id), [[base, base]])

      expect((base + 1).to_f).to eq base.to_f
      expect(subject.get(1, base + 1).map(&:id)).to eq [base]
    end

    it 'keeps an older same-score status when the ids in between are missing' do
      base = 9_007_199_254_740_992
      present = [base + 3, base + 5]
      missing = base + 4
      expect([missing, *present].map(&:to_f).uniq.size).to eq 1
      present.each { |id| Fabricate(:status, account: account, id: id, visibility: :public) }
      redis.zadd(FeedManager.instance.key(:home, account.id), (present + [missing]).map { |id| [id, id] })

      expect(subject.get(2).map(&:id)).to eq present.sort.reverse
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
