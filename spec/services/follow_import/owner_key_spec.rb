# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::OwnerKey do
  def batch_for(account)
    FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(account),
      imported_at: Time.now.utc,
      mode: :merge,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
  end

  it 'gives the same key to every batch of the same importing account' do
    account = Fabricate(:account)
    keys = Array.new(10) { described_class.for_batch(batch_for(account)) }

    expect(keys.uniq.size).to eq 1
    expect(keys.first).to eq described_class.from_account_id(account.id)
  end

  it 'gives different keys to different importing accounts' do
    first = described_class.for_batch(batch_for(Fabricate(:account)))
    second = described_class.for_batch(batch_for(Fabricate(:account)))

    expect(first).not_to eq second
  end

  it 'returns nil when the importing account cannot be derived' do
    batch = batch_for(Fabricate(:account))
    allow(batch).to receive(:for_account).and_return(nil)

    expect(described_class.for_batch(batch)).to be_nil
  end

  it 'does not expose a portable account-id scheduling contract' do
    key = described_class.from_account_id(12)

    expect(key.value).to eq 'a:12'
    expect(key).not_to respond_to(:account_id)
    expect(key).not_to respond_to(:subject_id)
  end
end
