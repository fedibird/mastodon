# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FanOutOnWriteService, 'edit subscription delivery' do # rubocop:disable Metrics/BlockLength
  let(:author) { Fabricate(:account, username: 'subauthor') }
  let(:subscriber_account) { Fabricate(:account, username: 'subuser') }
  let!(:subscriber) { Fabricate(:user, account: subscriber_account, current_sign_in_at: Time.now.utc) }
  let(:list) { Fabricate(:list, account: subscriber_account, title: 'Watched') }
  let(:tag) { Fabricate(:tag, name: 'editmatch') }
  let(:redis) { FeedManager.instance.__send__(:redis) }

  def calls_for(pushes, id)
    pushes.select { |args| args[1] == id }
  end

  def home_score
    redis.zscore(FeedManager.instance.key(:home, subscriber_account.id), status.id)
  end

  describe 'tag follow' do
    let(:status) { Fabricate(:status, account: author, text: 'before', visibility: :public) }

    before do
      subscriber
      tag_follow = TagFollow.find_or_create_by!(account: subscriber_account, tag: tag)
      TagFollowDelivery.create!(tag_follow: tag_follow, list: nil, media_only: false)
      redis.set("subscribed:timeline:#{subscriber_account.id}", '1')
    end

    it 'inserts a newly matching home feed entry as a new status and keeps it after the tag is removed' do
      pushes = []
      allow(PushUpdateWorker).to receive(:perform_async) { |*args| pushes << args }

      expect(HomeFeed.new(subscriber_account).get(10).map(&:id)).not_to include(status.id)

      status.update!(text: "now ##{tag.name}")
      ProcessHashtagsService.new.call(status, [], replace: true)
      described_class.new.call(status.reload, update: true)

      expect(HomeFeed.new(subscriber_account).get(10).map(&:id)).to include(status.id)
      expect(calls_for(pushes, status.id)).to include([subscriber_account.id, status.id, "timeline:#{subscriber_account.id}"])
      expect(calls_for(pushes, status.id)).not_to include([subscriber_account.id, status.id, "timeline:#{subscriber_account.id}", { 'update' => true }])
      score = home_score

      pushes.clear
      status.update!(text: "again ##{tag.name}")
      ProcessHashtagsService.new.call(status, [], replace: true)
      described_class.new.call(status.reload, update: true)

      expect(home_score.to_i).to eq score.to_i
      expect(calls_for(pushes, status.id)).to include([subscriber_account.id, status.id, "timeline:#{subscriber_account.id}", { 'update' => true }])

      pushes.clear
      status.update!(text: 'no longer matching')
      ProcessHashtagsService.new.call(status, [], replace: true)
      described_class.new.call(status.reload, update: true)

      expect(HomeFeed.new(subscriber_account).get(10).map(&:id)).to include(status.id)
      expect(home_score.to_i).to eq score.to_i
      expect(calls_for(pushes, status.id)).to be_empty
    end
  end

  describe 'keyword subscribe' do
    let(:status) { Fabricate(:status, account: author, text: 'before', visibility: :public) }

    before do
      subscriber
      KeywordSubscribe.create!(
        account: subscriber_account,
        name: 'edit watch',
        regexp: false,
        match_hashtags: false,
        match_urls: false,
        list_id: list.id,
        exclude_keyword: '',
        keyword: 'freshkeyword'
      )
      redis.set("subscribed:timeline:list:#{list.id}", '1')
    end

    it 'inserts a newly matching list as a new status and keeps it after the keyword is removed' do
      pushes = []
      allow(PushUpdateWorker).to receive(:perform_async) { |*args| pushes << args }
      list_key = FeedManager.instance.key(:list, list.id)

      expect(redis.zscore(list_key, status.id)).to be_nil

      status.update!(text: 'hello freshkeyword')
      described_class.new.call(status.reload, update: true)

      expect(redis.zscore(list_key, status.id)).not_to be_nil
      expect(calls_for(pushes, status.id)).to include([subscriber_account.id, status.id, "timeline:list:#{list.id}"])
      score = redis.zscore(list_key, status.id)

      pushes.clear
      status.update!(text: 'again freshkeyword')
      described_class.new.call(status.reload, update: true)

      expect(redis.zscore(list_key, status.id).to_i).to eq score.to_i
      expect(calls_for(pushes, status.id)).to include([subscriber_account.id, status.id, "timeline:list:#{list.id}", { 'update' => true }])

      pushes.clear
      status.update!(text: 'keyword gone')
      described_class.new.call(Status.find(status.id), update: true)

      expect(redis.zscore(list_key, status.id).to_i).to eq score.to_i
      expect(calls_for(pushes, status.id)).to be_empty
    end
  end
end
