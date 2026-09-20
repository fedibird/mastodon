# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::TagSerializer do
  let(:tag) { Fabricate(:tag, name: 'foo') }

  it 'keeps returning the raw name even when display_name is set' do
    tag.update!(display_name: 'FOO')

    serializer = described_class.new(tag)
    def serializer.current_user?
      false
    end

    json = JSON.parse(serializer.to_json, symbolize_names: true)

    expect(json[:name]).to eq 'foo'
    expect(json).not_to have_key(:trendable)
    expect(json).not_to have_key(:usable)
    expect(json).not_to have_key(:listable)
    expect(json).not_to have_key(:requires_review)
  end

  it 'reads following from TagFollow when no relationships presenter is supplied' do
    user = Fabricate(:user)
    TagFollow.create!(account: user.account, tag: tag)

    serializer = described_class.new(tag)
    allow(serializer).to receive(:current_user).and_return(user)
    json = JSON.parse(serializer.to_json, symbolize_names: true)

    expect(FollowTag.where(account: user.account, tag: tag)).to be_empty
    expect(json[:following]).to be true
  end

  it 'does not report following from callback-bypassing FollowTag without TagFollow' do
    user = Fabricate(:user)
    now = Time.now.utc
    FollowTag.insert_all!([{
      account_id: user.account.id,
      tag_id: tag.id,
      list_id: nil,
      media_only: false,
      created_at: now,
      updated_at: now,
    }])

    serializer = described_class.new(tag)
    allow(serializer).to receive(:current_user).and_return(user)
    json = JSON.parse(serializer.to_json, symbolize_names: true)

    expect(FollowTag.exists?(account: user.account, tag: tag)).to be true
    expect(TagFollow.where(account: user.account, tag: tag)).to be_empty
    expect(json[:following]).to be false
  end
end
