# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TagRelationshipsPresenter do
  let(:account) { Fabricate(:account) }
  let(:tag) { Fabricate(:tag, name: 'u3b1presenter') }

  it 'reports following from TagFollow even when FollowTag is absent' do
    TagFollow.create!(account: account, tag: tag)

    presenter = described_class.new([tag], account.id)

    expect(FollowTag.where(account: account, tag: tag)).to be_empty
    expect(presenter.following_map[tag.id]).to be true
  end

  it 'does not report following from callback-bypassing FollowTag without TagFollow' do
    now = Time.now.utc
    rows = [
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

    presenter = described_class.new([tag], account.id)

    expect(FollowTag.exists?(account: account, tag: tag)).to be true
    expect(TagFollow.where(account: account, tag: tag)).to be_empty
    expect(presenter.following_map[tag.id]).to be_nil
  end

  it 'returns an empty map without a current account' do
    TagFollow.create!(account: account, tag: tag)

    presenter = described_class.new([tag], nil)

    expect(presenter.following_map).to eq({})
  end
end
