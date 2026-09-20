# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe HashtagUnification::FollowTagParity do
  let!(:account) { Fabricate(:account) }
  let!(:tag) { Fabricate(:tag) }
  let!(:list) { Fabricate(:list, account: account) }

  before do
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
      {
        account_id: account.id,
        tag_id: tag.id,
        list_id: list.id,
        media_only: true,
        created_at: now,
        updated_at: now,
      },
    ]
    FollowTag.insert_all!(rows)
  end

  it 'reports callback-bypassing legacy rows as missing before backfill' do
    result = described_class.new.call

    expect(result[:ok]).to be false
    expect(result[:management_ready]).to be false
    expect(result.dig(:differences, :missing_tag_follows)).to eq 1
    expect(result.dig(:differences, :missing_deliveries)).to eq 2
  end

  it 'reports exact parity after backfill' do
    HashtagUnification::FollowTagBackfill.new(apply: true).call

    result = described_class.new.call

    expect(result[:ok]).to be true
    expect(result[:management_ready]).to be true
    expect(result[:differences].values).to all(be_zero)
    expect(result.dig(:target, :tag_follows_without_deliveries)).to eq 0
    expect(result.dig(:target, :deliveries_without_legacy_follow_tag_id)).to eq 0
  end

  it 'detects an incorrect media_only value' do
    HashtagUnification::FollowTagBackfill.new(apply: true).call
    TagFollowDelivery.list.update_all(media_only: false)

    result = described_class.new.call

    expect(result[:ok]).to be false
    expect(result[:management_ready]).to be false
    expect(result.dig(:differences, :media_only_mismatches)).to eq 1
  end

  it 'detects a missing compatibility resource ID on a source-backed delivery' do
    HashtagUnification::FollowTagBackfill.new(apply: true).call
    TagFollowDelivery.home.update_all(legacy_follow_tag_id: nil)

    result = described_class.new.call

    expect(result[:ok]).to be false
    expect(result[:management_ready]).to be false
    expect(result.dig(:target, :deliveries_without_legacy_follow_tag_id)).to eq 1
  end

  it 'detects a wrong compatibility resource ID' do
    HashtagUnification::FollowTagBackfill.new(apply: true).call
    unused_id = FollowTag.maximum(:id) + 1
    TagFollowDelivery.home.update_all(legacy_follow_tag_id: unused_id)

    result = described_class.new.call

    expect(result[:ok]).to be false
    expect(result[:management_ready]).to be false
    expect(result.dig(:differences, :legacy_follow_tag_id_mismatches)).to eq 1
  end

  it 'blocks management readiness when duplicate legacy destinations exist' do
    now = Time.now.utc
    FollowTag.insert_all!(
      [
        {
          account_id: account.id,
          tag_id: tag.id,
          list_id: nil,
          media_only: true,
          created_at: now,
          updated_at: now,
        },
      ]
    )
    HashtagUnification::FollowTagBackfill.new(apply: true).call

    result = described_class.new.call

    expect(result.dig(:source, :duplicate_destination_groups)).to eq 1
    expect(result[:ok]).to be true
    expect(result[:management_ready]).to be false
  end
end
# rubocop:enable Metrics/BlockLength
