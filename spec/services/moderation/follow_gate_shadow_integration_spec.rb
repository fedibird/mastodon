# frozen_string_literal: true

require 'rails_helper'

# FollowService wiring for the shadow follow-gate observation. The observer is
# stubbed here so we assert only the wiring (arguments + that the follow still
# succeeds); the observer/worker behaviour is covered in their own specs.
RSpec.describe 'FollowService shadow follow-gate wiring', type: :service do
  let(:alice) { Fabricate(:account, username: 'alice') }
  let(:bob)   { Fabricate(:account, username: 'bob', locked: false) }

  it 'observes the created follow with the source, target and derived mechanism' do
    expect(Moderation::FollowGateShadowObserver).to receive(:observe).with(
      source_account: alice, target_account: bob, mechanism: nil
    )

    follow = FollowService.new.call(alice, bob)
    expect(follow).to be_present
  end

  it 'derives the follow_import mechanism when an import batch id is passed' do
    expect(Moderation::FollowGateShadowObserver).to receive(:observe).with(
      hash_including(mechanism: 'follow_import')
    )

    FollowService.new.call(alice, bob, import_batch_id: 123)
  end

  it 'is safe by default (flag off): the follow succeeds and nothing is enqueued' do
    # Uses the real observer; with the flag off it no-ops.
    allow(Moderation::FollowGateShadowObserver).to receive(:enabled?).and_return(false)
    expect(Moderation::FollowGateShadowWorker).to_not receive(:perform_async)

    follow = FollowService.new.call(alice, bob)

    expect(follow).to be_present
    expect(alice.following?(bob)).to be true
  end
end
