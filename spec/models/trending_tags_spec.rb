require 'rails_helper'

RSpec.describe TrendingTags do
  describe '.record_use!' do
    pending
  end

  describe '.update!' do
    let!(:at_time) { Time.now.utc }
    let!(:tag1) { Fabricate(:tag, name: 'Catstodon', trendable: true) }
    let!(:tag2) { Fabricate(:tag, name: 'DogsOfMastodon', trendable: true) }
    let!(:tag3) { Fabricate(:tag, name: 'OCs', trendable: true) }

    before do
      allow(redis).to receive(:pfcount) do |key|
        case key
        when "activity:tags:#{tag1.id}:#{(at_time - 1.day).beginning_of_day.to_i}:accounts"
          2
        when "activity:tags:#{tag1.id}:#{at_time.beginning_of_day.to_i}:accounts"
          16
        when "activity:tags:#{tag2.id}:#{(at_time - 1.day).beginning_of_day.to_i}:accounts"
          0
        when "activity:tags:#{tag2.id}:#{at_time.beginning_of_day.to_i}:accounts"
          4
        when "activity:tags:#{tag3.id}:#{(at_time - 1.day).beginning_of_day.to_i}:accounts"
          13
        end
      end

      redis.zadd('trending_tags', 0.9, tag3.id)
      redis.sadd("trending_tags:used:#{at_time.beginning_of_day.to_i}", [tag1.id, tag2.id])

      tag3.update(max_score: 0.9, max_score_at: (at_time - 1.day).beginning_of_day + 12.hours)

      described_class.update!(at_time)
    end

    it 'calculates and re-calculates scores' do
      expect(described_class.get(10, filtered: false)).to eq [tag1]
    end

    it 'omits hashtags below threshold' do
      expect(described_class.get(10, filtered: false)).to_not include(tag2)
    end

    it 'drops a cooled-down score below the decay threshold' do
      expect(redis.zscore('trending_tags:all', tag3.id)).to be_nil
    end
  end

  describe '.trending?' do
    let(:tag) { Fabricate(:tag) }

    before do
      10.times { |i| redis.zadd('trending_tags', i + 1, Fabricate(:tag).id) }
    end

    it 'returns true if the hashtag is within limit' do
      redis.zadd('trending_tags:allowed', 11, tag.id)
      expect(described_class.trending?(tag)).to be true
    end

    it 'returns false if the hashtag is outside the limit' do
      redis.zadd('trending_tags', 0, tag.id)
      expect(described_class.trending?(tag)).to be false
    end
  end
end
