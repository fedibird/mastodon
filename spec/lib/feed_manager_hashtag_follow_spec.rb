# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeedManager do # rubocop:disable Metrics/BlockLength
  let(:alice) { Fabricate(:account, username: 'u3b2alice') }
  let(:bob) { Fabricate(:account, username: 'u3b2bob') }
  let(:jeff) { Fabricate(:account, username: 'u3b2jeff') }
  let(:tag) { Fabricate(:tag, name: 'u3b2admission') }
  let(:list_a) { Fabricate(:list, account: bob, title: 'A') }
  let(:list_b) { Fabricate(:list, account: bob, title: 'B') }

  def tagged_reply
    parent = Fabricate(:status, text: 'Hello world', account: jeff)
    reply = Fabricate(:status, text: "Nay ##{tag.name}", thread: parent, account: alice)
    ProcessHashtagsService.new.call(reply)
    reply.reload
  end

  def create_canonical_delivery(account:, tag:, list: nil)
    tag_follow = TagFollow.find_or_create_by!(account: account, tag: tag)
    TagFollowDelivery.create!(tag_follow: tag_follow, list: list)
  end

  def insert_legacy_follow_tag(account:, tag:, list: nil)
    now = Time.now.utc
    rows = [
      {
        account_id: account.id,
        tag_id: tag.id,
        list_id: list&.id,
        media_only: false,
        created_at: now,
        updated_at: now,
      },
    ]
    FollowTag.insert_all!(rows)
  end

  describe 'home reply admission' do
    before do
      bob.follow!(alice)
    end

    it 'filters a reply to an unfollowed account without a Home tag delivery' do
      expect(FeedManager.instance.filter?(:home, tagged_reply, bob)).to be true
    end

    it 'admits the reply when the receiver has a canonical Home delivery' do
      create_canonical_delivery(account: bob, tag: tag)
      expect(FollowTag.where(account: bob, tag: tag)).to be_empty

      expect(FeedManager.instance.filter?(:home, tagged_reply, bob)).to be false
    end

    it 'does not admit the reply for a List-only canonical delivery' do
      create_canonical_delivery(account: bob, tag: tag, list: list_a)

      expect(FeedManager.instance.filter?(:home, tagged_reply, bob)).to be true
    end

    it 'does not admit the reply for a bare TagFollow with no delivery' do
      TagFollow.create!(account: bob, tag: tag)

      expect(FeedManager.instance.filter?(:home, tagged_reply, bob)).to be true
    end

    it 'does not admit the reply for a callback-bypassing FollowTag Home row' do
      insert_legacy_follow_tag(account: bob, tag: tag)
      expect(TagFollow.where(account: bob, tag: tag)).to be_empty

      expect(FeedManager.instance.filter?(:home, tagged_reply, bob)).to be true
    end
  end

  describe 'list reply admission' do
    before do
      bob.follow!(alice)
      list_a.accounts << alice
    end

    it 'filters a reply to a non-member without a List tag delivery' do
      expect(FeedManager.instance.filter?(:list, tagged_reply, list_a)).to be true
    end

    it 'admits the reply when the owner has a canonical delivery to that List' do
      create_canonical_delivery(account: bob, tag: tag, list: list_a)
      expect(FollowTag.where(account: bob, tag: tag)).to be_empty

      expect(FeedManager.instance.filter?(:list, tagged_reply, list_a)).to be false
    end

    it 'does not admit the reply for a Home-only canonical delivery' do
      create_canonical_delivery(account: bob, tag: tag)

      expect(FeedManager.instance.filter?(:list, tagged_reply, list_a)).to be true
    end

    it 'does not admit the reply for a delivery to a different List' do
      create_canonical_delivery(account: bob, tag: tag, list: list_b)

      expect(FeedManager.instance.filter?(:list, tagged_reply, list_a)).to be true
    end

    it 'does not admit the reply for a callback-bypassing FollowTag List row' do
      insert_legacy_follow_tag(account: bob, tag: tag, list: list_a)
      expect(TagFollow.where(account: bob, tag: tag)).to be_empty

      expect(FeedManager.instance.filter?(:list, tagged_reply, list_a)).to be true
    end
  end

  describe 'U3a write bridge' do
    before do
      bob.follow!(alice)
    end

    it 'admits a Home reply after a normal FollowTag create mirrors the destination' do
      FollowTag.create!(account: bob, tag: tag)
      target = TagFollow.find_by!(account: bob, tag: tag)

      expect(target.deliveries.home.count).to eq 1
      expect(FeedManager.instance.filter?(:home, tagged_reply, bob)).to be false
    end

    it 'admits a List reply after a normal FollowTag list create mirrors the destination' do
      list_a.accounts << alice
      FollowTag.create!(account: bob, tag: tag, list: list_a)
      target = TagFollow.find_by!(account: bob, tag: tag)

      expect(target.deliveries.home).to be_empty
      expect(FeedManager.instance.filter?(:list, tagged_reply, list_a)).to be false
    end
  end
end
