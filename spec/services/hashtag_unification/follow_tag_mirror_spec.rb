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
    expect(TagFollowDelivery.home.find_by!(tag_follow: tag_follow).media_only).to be false
  end

  it 'removes the target relation when no legacy destinations remain' do
    follow_tag = FollowTag.create!(account: account, tag: tag)
    tag_follow_id = TagFollow.find_by!(account: account, tag: tag).id

    FollowTag.where(id: follow_tag.id).delete_all
    described_class.new(account_id: account.id, tag_id: tag.id).call

    expect(TagFollow.where(id: tag_follow_id)).to be_empty
    expect(TagFollowDelivery.where(tag_follow_id: tag_follow_id)).to be_empty
  end
end
