# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FanOutOnWriteService, type: :service do # rubocop:disable Metrics/BlockLength
  let(:author) { Fabricate(:account, username: 'hashtagauthor') }
  let(:follower) { Fabricate(:account, username: 'hashtagfollower') }
  let(:stranger) { Fabricate(:account, username: 'hashtagstranger') }
  let(:tag) { Fabricate(:tag, name: 'u3b2delivery') }
  let(:other_tag) { Fabricate(:tag, name: 'u3b2other') }
  let(:list_a) { Fabricate(:list, account: follower, title: 'A') }
  let(:list_b) { Fabricate(:list, account: follower, title: 'B') }

  def tagged_status(text: "hello ##{tag.name}", account: author)
    status = Fabricate(:status, account: account, text: text)
    ProcessHashtagsService.new.call(status)
    status.reload
  end

  def create_canonical_delivery(account:, tag:, list: nil, media_only: false)
    tag_follow = TagFollow.find_or_create_by!(account: account, tag: tag)
    TagFollowDelivery.create!(tag_follow: tag_follow, list: list, media_only: media_only)
  end

  def insert_legacy_follow_tag(account:, tag:, list: nil, media_only: false)
    now = Time.now.utc
    rows = [
      {
        account_id: account.id,
        tag_id: tag.id,
        list_id: list&.id,
        media_only: media_only,
        created_at: now,
        updated_at: now,
      },
    ]
    FollowTag.insert_all!(rows)
  end

  def capture_hashtag_targets(status)
    home_ids = nil
    list_ids = nil
    worker = double(:feed_insert_worker)
    allow(worker).to receive(:push_bulk) do |records|
      if home_ids.nil?
        home_ids = Array(records)
      else
        list_ids = Array(records)
      end
    end

    service = described_class.new
    service.instance_variable_set(:@feedInsertWorker, worker)
    service.send(:deliver_to_hashtag_followers, status)

    [home_ids || [], list_ids || []]
  end

  describe 'canonical destination delivery' do # rubocop:disable Metrics/BlockLength
    it 'delivers a Home-only canonical follow to Home and not to Lists' do
      create_canonical_delivery(account: follower, tag: tag)
      expect(FollowTag.where(account: follower, tag: tag)).to be_empty

      home_ids, list_ids = capture_hashtag_targets(tagged_status)

      expect(home_ids).to contain_exactly(follower.id)
      expect(list_ids).to eq([])
    end

    it 'delivers a List-only canonical follow only to that List' do
      create_canonical_delivery(account: follower, tag: tag, list: list_a)
      expect(FollowTag.where(account: follower, tag: tag)).to be_empty

      home_ids, list_ids = capture_hashtag_targets(tagged_status)

      expect(home_ids).to eq([])
      expect(list_ids).to contain_exactly(list_a.id)
    end

    it 'does not deliver a List-only follow to a different List' do
      create_canonical_delivery(account: follower, tag: tag, list: list_a)

      _home_ids, list_ids = capture_hashtag_targets(tagged_status)

      expect(list_ids).not_to include(list_b.id)
    end

    it 'delivers Home plus List to both destinations without duplicate IDs' do
      create_canonical_delivery(account: follower, tag: tag)
      create_canonical_delivery(account: follower, tag: tag, list: list_a)

      home_ids, list_ids = capture_hashtag_targets(tagged_status)

      expect(home_ids).to contain_exactly(follower.id)
      expect(list_ids).to contain_exactly(list_a.id)
    end

    it 'delivers multiple List destinations and not Home' do
      create_canonical_delivery(account: follower, tag: tag, list: list_a)
      create_canonical_delivery(account: follower, tag: tag, list: list_b)

      home_ids, list_ids = capture_hashtag_targets(tagged_status)

      expect(home_ids).to eq([])
      expect(list_ids).to contain_exactly(list_a.id, list_b.id)
    end

    it 'does not infer Home delivery from a bare TagFollow' do
      TagFollow.create!(account: follower, tag: tag)

      home_ids, list_ids = capture_hashtag_targets(tagged_status)

      expect(home_ids).to eq([])
      expect(list_ids).to eq([])
    end

    it 'uniq-collapses one Home account that follows two tags on the status' do
      create_canonical_delivery(account: follower, tag: tag)
      create_canonical_delivery(account: follower, tag: other_tag)
      status = tagged_status(text: "hello ##{tag.name} ##{other_tag.name}")

      home_ids, = capture_hashtag_targets(status)

      expect(home_ids).to contain_exactly(follower.id)
    end
  end

  describe 'read-source sentinels' do
    it 'does not deliver callback-bypassing FollowTag Home rows' do
      insert_legacy_follow_tag(account: follower, tag: tag)
      expect(FollowTag.exists?(account: follower, tag: tag)).to be true
      expect(TagFollow.where(account: follower, tag: tag)).to be_empty

      home_ids, list_ids = capture_hashtag_targets(tagged_status)

      expect(home_ids).to eq([])
      expect(list_ids).to eq([])
    end

    it 'does not deliver callback-bypassing FollowTag List rows' do
      insert_legacy_follow_tag(account: follower, tag: tag, list: list_a)
      expect(TagFollow.where(account: follower, tag: tag)).to be_empty

      home_ids, list_ids = capture_hashtag_targets(tagged_status)

      expect(home_ids).to eq([])
      expect(list_ids).to eq([])
    end
  end

  describe 'media_only' do
    def status_with_media
      status = tagged_status
      Fabricate(:media_attachment, account: author, status: status)
      status.reload
    end

    it 'blocks a text-only status from a Home media_only delivery' do
      create_canonical_delivery(account: follower, tag: tag, media_only: true)

      home_ids, = capture_hashtag_targets(tagged_status)

      expect(home_ids).to eq([])
    end

    it 'admits a media status to a Home media_only delivery' do
      create_canonical_delivery(account: follower, tag: tag, media_only: true)

      home_ids, = capture_hashtag_targets(status_with_media)

      expect(home_ids).to contain_exactly(follower.id)
    end

    it 'blocks a text-only status from a List media_only delivery' do
      create_canonical_delivery(account: follower, tag: tag, list: list_a, media_only: true)

      _, list_ids = capture_hashtag_targets(tagged_status)

      expect(list_ids).to eq([])
    end

    it 'admits a media status to a List media_only delivery' do
      create_canonical_delivery(account: follower, tag: tag, list: list_a, media_only: true)

      _, list_ids = capture_hashtag_targets(status_with_media)

      expect(list_ids).to contain_exactly(list_a.id)
    end
  end

  describe 'visibility_scope' do
    it 'does not deliver a public silenced status to a non-follower' do
      author.silence!
      create_canonical_delivery(account: stranger, tag: tag)

      home_ids, = capture_hashtag_targets(tagged_status)

      expect(home_ids).not_to include(stranger.id)
    end

    it 'delivers a public silenced status to a local follower' do
      author.silence!
      follower.follow!(author)
      create_canonical_delivery(account: follower, tag: tag)

      home_ids, = capture_hashtag_targets(tagged_status)

      expect(home_ids).to include(follower.id)
    end
  end

  describe 'tags_without_mute' do
    it 'does not deliver a tag muted by the author' do
      create_canonical_delivery(account: follower, tag: tag)
      Fabricate(:tag_account_mute, account: author, tag: tag)
      status = tagged_status

      expect(status.tags_without_mute).to be_empty

      home_ids, list_ids = capture_hashtag_targets(status)

      expect(home_ids).to eq([])
      expect(list_ids).to eq([])
    end
  end

  describe 'U3a write bridge' do
    it 'delivers Home after a normal FollowTag create mirrors the destination' do
      FollowTag.create!(account: follower, tag: tag)
      target = TagFollow.find_by!(account: follower, tag: tag)

      expect(target.deliveries.home.count).to eq 1

      home_ids, list_ids = capture_hashtag_targets(tagged_status)

      expect(home_ids).to contain_exactly(follower.id)
      expect(list_ids).to eq([])
    end

    it 'delivers List-only after a normal FollowTag list create mirrors the destination' do
      FollowTag.create!(account: follower, tag: tag, list: list_a)
      target = TagFollow.find_by!(account: follower, tag: tag)

      expect(target.deliveries.home).to be_empty
      expect(target.deliveries.list.pluck(:list_id)).to contain_exactly(list_a.id)

      home_ids, list_ids = capture_hashtag_targets(tagged_status)

      expect(home_ids).to eq([])
      expect(list_ids).to contain_exactly(list_a.id)
    end
  end
end
