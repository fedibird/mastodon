# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HashtagUnification::FollowTagMirror do
  let!(:account) { Fabricate(:account) }
  let!(:tag) { Fabricate(:tag, name: 'mirrorservice') }

  it 'collapses duplicate source destinations with false-wins semantics' do
    now = Time.now.utc
    rows = [
      {
        account_id: account.id,
        tag_id: tag.id,
        list_id: nil,
        media_only: true,
        created_at: now,
        updated_at: now,
      },
      {
        account_id: account.id,
        tag_id: tag.id,
        list_id: nil,
        media_only: false,
        created_at: now,
        updated_at: now,
      },
    ]
    FollowTag.insert_all!(rows)

    described_class.new(account_id: account.id, tag_id: tag.id).call

    tag_follow = TagFollow.find_by!(account: account, tag: tag)
    ids = FollowTag.where(account: account, tag: tag, list_id: nil).pluck(:id)
    delivery = TagFollowDelivery.home.find_by!(tag_follow: tag_follow)

    expect(delivery.media_only).to be false
    expect(delivery.legacy_follow_tag_id).to eq ids.min
  end

  it 'removes the target relation when no legacy destinations remain' do
    follow_tag = FollowTag.create!(account: account, tag: tag)
    tag_follow_id = TagFollow.find_by!(account: account, tag: tag).id

    FollowTag.where(id: follow_tag.id).delete_all
    described_class.new(account_id: account.id, tag_id: tag.id).call

    expect(TagFollow.where(id: tag_follow_id)).to be_empty
    expect(TagFollowDelivery.where(tag_follow_id: tag_follow_id)).to be_empty
  end

  it 'keeps the compatibility resource ID when a List destination moves to Home' do
    list = Fabricate(:list, account: account, title: 'A')
    follow_tag = FollowTag.create!(account: account, tag: tag, list: list)

    follow_tag.update!(list: nil)

    tag_follow = TagFollow.find_by!(account: account, tag: tag)
    delivery = TagFollowDelivery.home.find_by!(tag_follow: tag_follow)

    expect(tag_follow.deliveries.list).to be_empty
    expect(delivery.legacy_follow_tag_id).to eq follow_tag.id
  end
end
