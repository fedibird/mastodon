# frozen_string_literal: true

require 'rails_helper'

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
    expect(result.dig(:differences, :missing_tag_follows)).to eq 1
    expect(result.dig(:differences, :missing_deliveries)).to eq 2
  end

  it 'reports exact parity after backfill' do
    HashtagUnification::FollowTagBackfill.new(apply: true).call

    result = described_class.new.call

    expect(result[:ok]).to be true
    expect(result[:differences].values).to all(be_zero)
    expect(result.dig(:target, :tag_follows_without_deliveries)).to eq 0
  end

  it 'detects an incorrect media_only value' do
    HashtagUnification::FollowTagBackfill.new(apply: true).call
    TagFollowDelivery.list.update_all(media_only: false)

    result = described_class.new.call

    expect(result[:ok]).to be false
    expect(result.dig(:differences, :media_only_mismatches)).to eq 1
  end
end
