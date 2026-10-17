require 'rails_helper'

RSpec.describe HomeFeed, type: :model do
  let(:account) { Fabricate(:account) }

  subject { described_class.new(account) }

  describe '#get' do
    before do
      Fabricate(:status, account: account, id: 1)
      Fabricate(:status, account: account, id: 2)
      Fabricate(:status, account: account, id: 3)
      Fabricate(:status, account: account, id: 10)
    end

    context 'when feed is generated' do
      before do
        redis.zadd(
          FeedManager.instance.key(:home, account.id),
          [[4, 4], [3, 3], [2, 2], [1, 1]]
        )
      end

      it 'gets statuses with ids in the range from redis' do
        results = subject.get(3)

        expect(results.map(&:id)).to eq [3, 2]
      end
    end

    context 'with a visibility filter' do
      before do
        60.times do |index|
          id = index + 101
          Fabricate(:status, account: account, id: id, visibility: id.even? ? :private : :public)
        end

        redis.zadd(
          FeedManager.instance.key(:home, account.id),
          (101..160).map { |id| [id, id] }
        )
      end

      it 'returns the visible page next to min_id, newest first' do
        results = subject.get(20, nil, nil, 100, ['public'])

        expect(results.map(&:id)).to eq(139.downto(101).select(&:odd?))
      end

      it 'returns the visible page next to max_id, newest first' do
        results = subject.get(5, 150, nil, nil, ['public'])

        expect(results.map(&:id)).to eq([149, 147, 145, 143, 141])
      end
    end

    context 'when feed is being generated' do
      before do
        redis.set("account:#{account.id}:regeneration", true)
      end

      it 'returns nothing' do
        results = subject.get(3)

        expect(results.map(&:id)).to eq []
      end
    end
  end
end
