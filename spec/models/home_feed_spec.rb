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

      it 'fills the page when a redis id is missing from the database' do
        results = subject.get(3)

        expect(results.map(&:id)).to eq [3, 2, 1]
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

    context 'when requesting only media' do
      before do
        first = Fabricate(:status, account: account, id: 201)
        Fabricate(:status, account: account, id: 202)
        last = Fabricate(:status, account: account, id: 203)
        Fabricate(:status, account: account, id: 204)
        attach_remote_test_image(first)
        attach_remote_test_image(last)

        redis.zadd(
          FeedManager.instance.key(:home, account.id),
          [[201, first.id], [202, 202], [203, last.id], [204, 204]]
        )
      end

      it 'refills past text-only ids before limiting the page' do
        expect(subject.get(1, nil, nil, nil, [], only_media: true).map(&:id)).to eq [203]
        expect(subject.get(1, 203, nil, nil, [], only_media: true).map(&:id)).to eq [201]
      end

      it 'keeps ordinary retrieval unchanged' do
        expect(subject.get(4).map(&:id)).to eq [204, 203, 202, 201]
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
