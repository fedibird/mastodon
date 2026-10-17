# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Feed, type: :model do
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

    it 'returns the next newer page when ids above min_id are gone' do
      (341..360).each do |id|
        Fabricate(:status, account: account, id: id)
      end
      redis.zadd(FeedManager.instance.key(:home, account.id), (321..360).map { |id| [id, id] })

      expect(subject.get(20, nil, nil, 320).map(&:id)).to eq(360.downto(341).to_a)
    end
  end
end
