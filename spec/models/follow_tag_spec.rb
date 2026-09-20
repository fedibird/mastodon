# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowTag, type: :model do
  let!(:account) { Fabricate(:account) }
  let!(:tag) { Fabricate(:tag, name: 'dualwrite') }
  let!(:list_a) { Fabricate(:list, account: account, title: 'A') }
  let!(:list_b) { Fabricate(:list, account: account, title: 'B') }

  it 'mirrors an explicit Home destination on create' do
    described_class.create!(account: account, tag: tag, media_only: true)

    target = TagFollow.find_by!(account: account, tag: tag)
    delivery = TagFollowDelivery.home.find_by!(tag_follow: target)

    expect(delivery.media_only).to be true
  end

  it 'keeps a List-only follow List-only' do
    described_class.create!(account: account, tag: tag, list: list_a)

    target = TagFollow.find_by!(account: account, tag: tag)

    expect(target.deliveries.home).to be_empty
    expect(target.deliveries.list.pluck(:list_id)).to contain_exactly(list_a.id)
  end

  it 'mirrors multiple peer destinations into one TagFollow' do
    described_class.create!(account: account, tag: tag)
    described_class.create!(account: account, tag: tag, list: list_a)

    target = TagFollow.find_by!(account: account, tag: tag)

    expect(TagFollow.where(account: account, tag: tag).count).to eq 1
    expect(target.deliveries.home.count).to eq 1
    expect(target.deliveries.list.pluck(:list_id)).to contain_exactly(list_a.id)
  end

  it 'mirrors media_only updates' do
    source = described_class.create!(account: account, tag: tag, media_only: false)
    source.update!(media_only: true)

    target = TagFollow.find_by!(account: account, tag: tag)
    expect(TagFollowDelivery.home.find_by!(tag_follow: target).media_only).to be true
  end

  it 'removes the old destination when list_id changes' do
    source = described_class.create!(account: account, tag: tag, list: list_a)
    source.update!(list: list_b)

    target = TagFollow.find_by!(account: account, tag: tag)

    expect(target.deliveries.list.pluck(:list_id)).to contain_exactly(list_b.id)
  end

  it 'keeps the relation while another destination remains' do
    home = described_class.create!(account: account, tag: tag)
    described_class.create!(account: account, tag: tag, list: list_a)

    home.destroy!

    target = TagFollow.find_by!(account: account, tag: tag)
    expect(target.deliveries.home).to be_empty
    expect(target.deliveries.list.pluck(:list_id)).to contain_exactly(list_a.id)
  end

  it 'removes the TagFollow when its final destination is destroyed' do
    source = described_class.create!(account: account, tag: tag)

    source.destroy!

    expect(TagFollow.where(account: account, tag: tag)).to be_empty
    expect(TagFollowDelivery.count).to eq 0
  end
end
