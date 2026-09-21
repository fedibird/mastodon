# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::Eligibility do
  def create_batch(preflight_state:)
    FollowImportBatch.create!(
      subject: Fabricate(:moderation_subject),
      imported_at: Time.now.utc,
      mode: :merge,
      dispatch_cohort: :operational,
      preflight_state: preflight_state,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
  end

  it 'treats only ready batches as executable' do
    expect(described_class.executable?(create_batch(preflight_state: :ready))).to be true
    expect(described_class.executable?(create_batch(preflight_state: :screening))).to be false
    expect(described_class.executable?(create_batch(preflight_state: :review_required))).to be false
    expect(described_class.executable?(create_batch(preflight_state: :stopped))).to be false
  end
end
