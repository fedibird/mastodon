# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImportBatch do
  let(:subject_record) { Fabricate(:moderation_subject) }

  def create_batch(**attrs)
    described_class.create!(
      {
        subject: subject_record,
        imported_at: Time.now.utc,
        mode: :merge,
        target_count: 0,
        resolved_target_count: 0,
        unresolved_target_count: 0,
      }.merge(attrs)
    )
  end

  it 'defaults new rows to legacy dispatch ownership' do
    batch = create_batch

    expect(batch.dispatch_owner).to eq 'legacy'
    expect(batch.legacy_dispatch_owner?).to be true
    expect(batch.scheduler_dispatch_owner?).to be false
  end

  it 'accepts scheduler ownership when the application selects it' do
    batch = create_batch(dispatch_owner: :scheduler)

    expect(batch.scheduler_dispatch_owner?).to be true
    expect(batch.legacy_dispatch_owner?).to be false
    expect(described_class.scheduler_owned).to include(batch)
    expect(described_class.legacy_owned).not_to include(batch)
  end

  it 'rejects an unsupported dispatch_owner' do
    expect { create_batch(dispatch_owner: :remote) }.to raise_error(ArgumentError)
  end
end
