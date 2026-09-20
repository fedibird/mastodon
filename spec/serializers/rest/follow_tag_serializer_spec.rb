# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::FollowTagSerializer do
  def json_for(object)
    JSON.parse(described_class.new(object).to_json, symbolize_names: true)
  end

  it 'serializes a FollowTag id as a string' do
    follow_tag = FollowTag.create!(account: Fabricate(:account), tag: Fabricate(:tag, name: 'legacywrite'))
    json = json_for(follow_tag)

    expect(json.keys).to contain_exactly(:id, :name, :updated_at)
    expect(json[:id]).to eq follow_tag.id.to_s
    expect(json[:name]).to eq 'legacywrite'
  end

  it 'serializes a TagFollowDelivery by legacy_resource_id, not canonical PK' do
    account = Fabricate(:account)
    tag = Fabricate(:tag, name: 'canonicalread')
    tag_follow = TagFollow.create!(account: account, tag: tag)
    unused_id = [
      FollowTag.maximum(:id) || 0,
      TagFollowDelivery.maximum(:id) || 0,
    ].max + 1_000_000
    delivery = TagFollowDelivery.create!(tag_follow: tag_follow, legacy_follow_tag_id: unused_id)
    json = json_for(delivery)

    expect(delivery.id).not_to eq unused_id
    expect(json.keys).to contain_exactly(:id, :name, :updated_at)
    expect(json[:id]).to eq unused_id.to_s
    expect(json[:id]).not_to eq delivery.id.to_s
    expect(json[:name]).to eq 'canonicalread'
  end

  it 'does not fall back to the canonical PK when the compatibility ID is missing' do
    tag_follow = TagFollow.create!(account: Fabricate(:account), tag: Fabricate(:tag))
    delivery = TagFollowDelivery.create!(tag_follow: tag_follow)

    expect { json_for(delivery) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
