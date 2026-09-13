# frozen_string_literal: true

require 'rails_helper'

# End-to-end wiring: a follow executed by a follow import (import_batch_id set)
# to a remote ActivityPub target must persist the target's correlation URI +
# queued state BEFORE the Follow is enqueued for delivery, and must attach opaque
# delivery-tracking metadata to the delivery. Normal follows must be untouched.
RSpec.describe 'FollowService follow-import delivery tracking' do
  let(:source) { Fabricate(:account) }
  let(:target) do
    Fabricate(:account, domain: 'example.com', uri: 'https://example.com/users/bob',
                        inbox_url: 'https://example.com/inbox', protocol: :activitypub)
  end
  let(:target_subject) { ModerationSubject.for_account!(target) }
  let(:batch) do
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 1, resolved_target_count: 1, unresolved_target_count: 0)
  end
  let!(:import_target) { batch.targets.create!(target_subject: target_subject, position: 0) }

  def capture_delivery
    captured = nil
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async) { |*args| captured = args }
    yield
    captured
  end

  it 'queues the target with follow_request_uri and attaches tracking to the delivery' do
    args = capture_delivery { FollowService.new.call(source, target, import_batch_id: batch.id) }

    import_target.reload
    expect(import_target.state).to eq 'queued'
    expect(import_target.follow_request_uri).to be_present

    follow_request = source.follow_requests.find_by(target_account: target)
    expect(import_target.follow_request_uri).to eq follow_request.uri

    options = args.last
    expect(options['delivery_tracking']).to eq({ 'type' => 'follow_import_target', 'id' => import_target.id })
  end

  it 'attaches no delivery tracking for a normal (non-import) follow' do
    args = capture_delivery { FollowService.new.call(source, target) }

    expect(args.last).not_to have_key('delivery_tracking')
    expect(import_target.reload.state).to eq 'pending'
  end

  it 'does not break the follow when tracking setup fails' do
    allow(FollowImport::TargetTransitionService).to receive(:new).and_raise(StandardError, 'boom')

    args = capture_delivery { FollowService.new.call(source, target, import_batch_id: batch.id) }

    expect(source.requested?(target)).to be true
    expect(args.last).not_to have_key('delivery_tracking')
  end
end
