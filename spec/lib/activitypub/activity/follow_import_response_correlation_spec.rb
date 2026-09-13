# frozen_string_literal: true

require 'rails_helper'

# End-to-end: an inbound Accept/Reject of a follow request that originated from a
# follow import must correlate back to its FollowImportTarget (via the durable
# follow_request_uri) and record the response, without disturbing the normal
# Accept/Reject handling.
RSpec.describe 'Inbound Accept/Reject correlation to follow-import targets' do
  let(:remote)    { Fabricate(:account, domain: 'example.com', uri: 'https://example.com/users/bob') }
  let(:requester) { Fabricate(:account) }

  let(:batch) do
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 1, resolved_target_count: 1, unresolved_target_count: 0)
  end

  let(:target_subject) { ModerationSubject.for_account!(remote) }

  # A follow request the local requester sent to the remote account, plus the
  # follow-import target correlated to it and waiting on a response.
  let!(:follow_request) { Fabricate(:follow_request, account: requester, target_account: remote) }
  let!(:import_target) do
    target = batch.targets.create!(target_subject: target_subject, position: 0)
    transitions = FollowImport::TargetTransitionService.new
    transitions.mark_queued(target, follow_request_uri: follow_request.uri)
    transitions.mark_awaiting_response(target, follow_request_uri: follow_request.uri, response_deadline_at: 1.day.from_now)
    target
  end

  def embedded_follow_activity(type)
    {
      '@context': 'https://www.w3.org/ns/activitystreams',
      id: "https://example.com/#{type.downcase}/1",
      type: type,
      actor: ActivityPub::TagManager.instance.uri_for(remote),
      object: {
        id: follow_request.uri,
        type: 'Follow',
        actor: ActivityPub::TagManager.instance.uri_for(requester),
        object: ActivityPub::TagManager.instance.uri_for(remote),
      },
    }.with_indifferent_access
  end

  before { allow(RemoteAccountRefreshWorker).to receive(:perform_async) }

  it 'marks the target accepted on an inbound Accept and still authorizes the follow' do
    ActivityPub::Activity::Accept.new(embedded_follow_activity('Accept'), remote).perform

    expect(import_target.reload.state).to eq 'accepted'
    expect(requester.following?(remote)).to be true
  end

  it 'marks the target rejected on an inbound Reject and still removes the request' do
    ActivityPub::Activity::Reject.new(embedded_follow_activity('Reject'), remote).perform

    expect(import_target.reload.state).to eq 'rejected'
    expect(requester.requested?(remote)).to be false
  end
end
