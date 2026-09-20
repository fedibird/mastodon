# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe HashtagUnification::FollowTagBackfill do
  let!(:account) { Fabricate(:account) }
  let!(:other_account) { Fabricate(:account) }
  let!(:home_tag) { Fabricate(:tag, name: 'homebackfill') }
  let!(:list_tag) { Fabricate(:tag, name: 'listbackfill') }
  let!(:mixed_tag) { Fabricate(:tag, name: 'mixedbackfill') }
  let!(:list_a) { Fabricate(:list, account: account, title: 'A') }
  let!(:list_b) { Fabricate(:list, account: account, title: 'B') }

  before do
    now = Time.now.utc
    rows = [
      legacy_row(account: account, tag: home_tag, list: nil, media_only: false, now: now),
      legacy_row(account: account, tag: list_tag, list: list_a, media_only: true, now: now),
      legacy_row(account: account, tag: list_tag, list: list_b, media_only: false, now: now),
      legacy_row(account: account, tag: mixed_tag, list: nil, media_only: true, now: now),
      legacy_row(account: account, tag: mixed_tag, list: list_a, media_only: false, now: now),
    ]
    FollowTag.insert_all!(rows)
  end

  it 'is dry-run by default' do
    result = described_class.new.call

    expect(result[:mode]).to eq 'dry-run'
    expect(TagFollow.count).to eq 0
    expect(TagFollowDelivery.count).to eq 0
  end

  it 'backfills one TagFollow per account/tag and explicit peer destinations' do
    result = described_class.new(apply: true).call

    expect(result.dig(:after, :ok)).to be true
    expect(TagFollow.count).to eq 3
    expect(TagFollowDelivery.count).to eq 5

    list_follow = TagFollow.find_by!(account: account, tag: list_tag)
    expect(list_follow.deliveries.home).to be_empty
    expect(list_follow.deliveries.list.pluck(:list_id)).to contain_exactly(list_a.id, list_b.id)

    mixed_follow = TagFollow.find_by!(account: account, tag: mixed_tag)
    expect(mixed_follow.deliveries.home.count).to eq 1
    expect(mixed_follow.deliveries.list.pluck(:list_id)).to contain_exactly(list_a.id)
  end

  it 'is idempotent and tracks later callback-bypassing media_only changes in the source' do
    described_class.new(apply: true).call

    FollowTag.where(account: account, tag: mixed_tag, list_id: nil).update_all(media_only: false)
    described_class.new(apply: true).call

    target = TagFollow.find_by!(account: account, tag: mixed_tag)
    expect(TagFollowDelivery.home.find_by!(tag_follow: target).media_only).to be false

    FollowTag.where(account: account, tag: mixed_tag, list_id: nil).update_all(media_only: true)
    described_class.new(apply: true).call

    expect(TagFollowDelivery.home.find_by!(tag_follow: target).media_only).to be true
  end

  it 'uses false-wins semantics when duplicate legacy destinations disagree on media_only' do
    now = Time.now.utc
    rows = [
      legacy_row(account: other_account, tag: home_tag, list: nil, media_only: true, now: now),
      legacy_row(account: other_account, tag: home_tag, list: nil, media_only: false, now: now),
    ]
    FollowTag.insert_all!(rows)

    described_class.new(apply: true).call

    target = TagFollow.find_by!(account: other_account, tag: home_tag)
    expect(TagFollowDelivery.home.find_by!(tag_follow: target).media_only).to be false
  end

  it 'does not delete target-only rows unless pruning is explicitly requested' do
    described_class.new(apply: true).call
    FollowTag.where(account: account, tag: home_tag).delete_all

    result = described_class.new(apply: true).call

    expect(result.dig(:after, :differences, :extra_tag_follows)).to eq 1
    expect(TagFollow.exists?(account: account, tag: home_tag)).to be true

    pruned = described_class.new(apply: true, prune: true).call

    expect(pruned.dig(:after, :ok)).to be true
    expect(TagFollow.exists?(account: account, tag: home_tag)).to be false
  end

  it 'refuses a callback-bypassing legacy List destination owned by a different account' do
    foreign_tag = Fabricate(:tag)
    foreign_list = Fabricate(:list, account: other_account)
    now = Time.now.utc

    rows = [
      legacy_row(account: account, tag: foreign_tag, list: foreign_list, media_only: false, now: now),
    ]
    FollowTag.insert_all!(rows)

    expect { described_class.new(apply: true).call }
      .to raise_error(described_class::UnsafeSourceDataError)

    expect(TagFollow.count).to eq 0
    expect(TagFollowDelivery.count).to eq 0
  end

  def legacy_row(account:, tag:, list:, media_only:, now:)
    {
      account_id: account.id,
      tag_id: tag.id,
      list_id: list&.id,
      media_only: media_only,
      created_at: now,
      updated_at: now,
    }
  end
end
# rubocop:enable Metrics/BlockLength
