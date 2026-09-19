# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TagFollow, type: :model do
  let(:account) { Fabricate(:account) }
  let(:tag) { Fabricate(:tag) }

  it 'stores the canonical account/tag follow relation independently of destinations' do
    tag_follow = described_class.create!(account: account, tag: tag)

    expect(tag_follow.deliveries).to be_empty
  end

  it 'destroys delivery extensions with the parent relation' do
    tag_follow = described_class.create!(account: account, tag: tag)
    delivery = TagFollowDelivery.create!(tag_follow: tag_follow)

    tag_follow.destroy!

    expect(TagFollowDelivery.where(id: delivery.id)).to be_empty
  end
end
