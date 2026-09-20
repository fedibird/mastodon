# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Form::FollowTag do
  it 'reuses the FollowTag model name so forms keep the follow_tag param key' do
    expect(described_class.model_name).to eq FollowTag.model_name
    expect(described_class.model_name.param_key).to eq 'follow_tag'
  end

  it 'is persisted only when a compatibility ID is present' do
    expect(described_class.new).not_to be_persisted
    expect(described_class.new(id: 12)).to be_persisted
  end

  it 'builds edit values from a canonical delivery' do
    account = Fabricate(:account)
    tag = Fabricate(:tag, name: 'u3b3dform')
    list = Fabricate(:list, account: account, title: 'A')
    tag_follow = TagFollow.create!(account: account, tag: tag)
    delivery = TagFollowDelivery.create!(
      tag_follow: tag_follow,
      list: list,
      media_only: true,
      legacy_follow_tag_id: 42
    )
    form = described_class.from_delivery(delivery)

    expect(form.id).to eq 42
    expect(form.name).to eq 'u3b3dform'
    expect(form.list_id).to eq list.id
    expect(form.media_only).to be true
    expect(form).to be_persisted
  end

  it 'requires a name' do
    form = described_class.new(name: '')

    expect(form).not_to be_valid
    expect(form.errors[:name]).to be_present
  end
end
