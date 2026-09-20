# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TagFollowDelivery, type: :model do # rubocop:disable Metrics/BlockLength
  let(:account) { Fabricate(:account) }
  let(:tag) { Fabricate(:tag) }
  let(:tag_follow) { TagFollow.create!(account: account, tag: tag) }
  let(:list_a) { Fabricate(:list, account: account, title: 'A') }
  let(:list_b) { Fabricate(:list, account: account, title: 'B') }

  it 'represents Home only with an explicit row whose list_id is nil' do
    expect(tag_follow.deliveries).to be_empty

    home = described_class.create!(tag_follow: tag_follow)

    expect(home.list_id).to be_nil
    expect(described_class.home).to contain_exactly(home)
  end

  it 'allows a lists-only follow without synthesizing Home' do
    delivery = described_class.create!(tag_follow: tag_follow, list: list_a)

    expect(described_class.home).to be_empty
    expect(described_class.list).to contain_exactly(delivery)
  end

  it 'allows Home after a List-only destination already exists' do
    list_delivery = described_class.create!(tag_follow: tag_follow, list: list_a)
    home = described_class.create!(tag_follow: tag_follow)

    expect(home.list_id).to be_nil
    expect(described_class.home).to contain_exactly(home)
    expect(described_class.list).to contain_exactly(list_delivery)
    expect(tag_follow.deliveries.reload).to contain_exactly(home, list_delivery)
  end

  it 'allows multiple peer destinations for one TagFollow' do
    home = described_class.create!(tag_follow: tag_follow)
    first_list = described_class.create!(tag_follow: tag_follow, list: list_a)
    second_list = described_class.create!(tag_follow: tag_follow, list: list_b)

    expect(tag_follow.deliveries.reload).to contain_exactly(home, first_list, second_list)
  end

  it 'allows media_only to differ by destination' do
    home = described_class.create!(tag_follow: tag_follow, media_only: false)
    list_delivery = described_class.create!(tag_follow: tag_follow, list: list_a, media_only: true)

    expect(home.media_only).to be false
    expect(list_delivery.media_only).to be true
  end

  it 'rejects a second Home destination' do
    described_class.create!(tag_follow: tag_follow)

    duplicate = described_class.new(tag_follow: tag_follow)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:tag_follow_id]).to be_present
  end

  it 'rejects a duplicate concrete List destination' do
    described_class.create!(tag_follow: tag_follow, list: list_a)

    duplicate = described_class.new(tag_follow: tag_follow, list: list_a)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:list_id]).to be_present
  end

  it 'rejects a List owned by a different account' do
    foreign_list = Fabricate(:list, account: Fabricate(:account))

    delivery = described_class.new(tag_follow: tag_follow, list: foreign_list)

    expect(delivery).not_to be_valid
    expect(delivery.errors[:list]).to be_present
  end

  it 'scopes deliveries to the requested tags through TagFollow' do
    other_tag = Fabricate(:tag)
    other_follow = TagFollow.create!(account: account, tag: other_tag)
    matching = described_class.create!(tag_follow: tag_follow)
    described_class.create!(tag_follow: other_follow)

    expect(described_class.for_tags([tag])).to contain_exactly(matching)
  end

  it 'rejects a duplicate non-null compatibility resource ID' do
    other_follow = TagFollow.create!(account: account, tag: Fabricate(:tag))
    unused_id = (FollowTag.maximum(:id) || 0) + 1
    described_class.create!(tag_follow: tag_follow, legacy_follow_tag_id: unused_id)

    duplicate = described_class.new(tag_follow: other_follow, legacy_follow_tag_id: unused_id)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:legacy_follow_tag_id]).to be_present
  end

  it 'allows multiple deliveries with a nil compatibility resource ID' do
    home = described_class.create!(tag_follow: tag_follow)
    list_delivery = described_class.create!(tag_follow: tag_follow, list: list_a)

    expect(home.legacy_follow_tag_id).to be_nil
    expect(list_delivery.legacy_follow_tag_id).to be_nil
    expect(home).to be_valid
    expect(list_delivery).to be_valid
  end

  it 'exposes the compatibility resource ID and never falls back to the canonical PK' do
    unused_id = (FollowTag.maximum(:id) || 0) + 1_000_000
    delivery = described_class.create!(tag_follow: tag_follow, legacy_follow_tag_id: unused_id)

    expect(delivery.legacy_resource_id).to eq unused_id
    expect(delivery.legacy_resource_id).not_to eq delivery.id
    expect(delivery.name).to eq tag.name
  end

  it 'raises when a compatibility resource ID is missing' do
    delivery = described_class.create!(tag_follow: tag_follow)

    expect { delivery.legacy_resource_id }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'scopes deliveries to the requested account through TagFollow' do
    other_account = Fabricate(:account)
    other_follow = TagFollow.create!(account: other_account, tag: Fabricate(:tag))
    matching = described_class.create!(tag_follow: tag_follow)
    described_class.create!(tag_follow: other_follow)

    expect(described_class.for_account(account)).to contain_exactly(matching)
  end
end
