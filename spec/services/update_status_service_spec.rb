# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UpdateStatusService, type: :service do # rubocop:disable Metrics/BlockLength
  subject { described_class.new }

  let(:account) { Fabricate(:account, username: 'alice') }
  let!(:status) { Fabricate(:status, account: account, text: 'original text', spoiler_text: '', sensitive: false, visibility: :unlisted, searchability: :private) }

  before do
    allow(DistributionWorker).to receive(:perform_async)
    allow(PriorityDistributionWorker).to receive(:perform_async)
    allow(ActivityPub::StatusUpdateDistributionWorker).to receive(:perform_async)
    allow(LinkCrawlWorker).to receive(:perform_async)
    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
    allow(PollExpirationNotifyWorker).to receive(:perform_at)
    allow(PollExpirationNotifyWorker).to receive(:remove_from_scheduled)
  end

  it 'stores the original and current snapshots and broadcasts an update' do
    subject.call(status, account.id, text: 'edited text', spoiler_text: 'cw', sensitive: true, language: 'en')

    status.reload
    edits = status.edits.to_a

    expect(status.text).to eq 'edited text'
    expect(status.spoiler_text).to eq 'cw'
    expect(status.sensitive).to be true
    expect(status.language).to eq 'en'
    expect(status.edited_at).to be_present
    expect(edits.map(&:text)).to eq ['original text', 'edited text']
    expect(edits.first.created_at).to be_within(1.second).of(status.created_at)
    expect(edits.last.created_at).to be_within(1.second).of(status.edited_at)
    expect(DistributionWorker).to have_received(:perform_async).with(status.id, { 'update' => true })
    expect(ActivityPub::StatusUpdateDistributionWorker).to have_received(:perform_async).with(status.id)
  end

  it 'returns the current status without a snapshot or broadcast when nothing changed' do
    expect { subject.call(status, account.id, text: 'original text') }.not_to(change { status.reload.edited_at })

    expect(status.edits).to be_empty
    expect(DistributionWorker).not_to have_received(:perform_async)
    expect(ActivityPub::StatusUpdateDistributionWorker).not_to have_received(:perform_async)
  end

  it 'rolls the edit and its snapshot back when validation fails' do
    expect { subject.call(status, account.id, text: '') }.to raise_error(ActiveRecord::RecordInvalid)

    status.reload
    expect(status.text).to eq 'original text'
    expect(status.edited_at).to be_nil
    expect(status.edits).to be_empty
    expect(DistributionWorker).not_to have_received(:perform_async)
  end

  it 'keeps quote, references, visibility, searchability, expiry, and the application' do
    quoted = Fabricate(:status, visibility: :public)
    referenced = Fabricate(:status, visibility: :public)
    application = Fabricate(:application)
    expires_at = 2.days.from_now.change(usec: 0)
    silent = Fabricate(:account, username: 'silent')
    status.update!(quote_id: quoted.id, application_id: application.id, visibility: :limited, searchability: :private)
    StatusReference.create!(status_id: status.id, target_status_id: referenced.id)
    expire = StatusExpire.create!(status: status, expires_at: expires_at, action: :mark)
    status.mentions.create!(account: silent, silent: true)

    subject.call(
      status,
      account.id,
      text: 'edited text',
      visibility: 'public',
      quote_id: Fabricate(:status).id,
      searchability: 'public',
      circle_id: 99,
      expires_at: 1.hour.from_now
    )

    status.reload
    expect(status.text).to eq 'edited text'
    expect(status.quote_id).to eq quoted.id
    expect(status.reference_relationships.pluck(:target_status_id)).to eq [referenced.id]
    expect(status.visibility).to eq 'limited'
    expect(status.searchability).to eq 'private'
    expect(status.application_id).to eq application.id
    expect(status.expired_at).to be_nil
    expect(expire.reload.expires_at).to be_within(1.second).of(expires_at)
    expect(expire.action).to eq 'mark'
    expect(status.mentions.find_by(account: silent).silent).to be true
  end

  it 'reorders owned media and keeps the historical description' do
    first = unprocessed_media(account, 'first')
    second = unprocessed_media(account, 'second')
    first.update_columns(status_id: status.id)
    second.update_columns(status_id: status.id)
    status.update!(ordered_media_attachment_ids: [first.id, second.id])
    status.media_attachments.reset

    subject.call(status, account.id, text: 'original text', media_ids: [second.id, first.id], media_attributes: [{ id: first.id, description: 'updated first' }])

    status.reload
    expect(status.ordered_media_attachment_ids).to eq [second.id, first.id]
    expect(first.reload.description).to eq 'updated first'
    expect(status.edits.first.media_descriptions).to eq %w(first second)
    expect(status.edits.last.media_descriptions).to eq ['second', 'updated first']
  end

  it 'does not attach another account\'s media' do
    owned = unprocessed_media(account, 'owned')
    foreign = unprocessed_media(Fabricate(:account, username: 'bob'), 'foreign')
    owned.update_columns(status_id: status.id)

    subject.call(status, account.id, text: 'original text', media_ids: [foreign.id, owned.id])

    expect(status.reload.ordered_media_attachment_ids).to eq [owned.id]
    expect(foreign.reload.status_id).to be_nil
  end

  it 'resets votes when poll options change and can remove the poll' do
    poll = Poll.create!(account: account, status: status, options: %w(One Two), expires_at: 2.days.from_now, multiple: false)
    status.update!(poll_id: poll.id)
    Fabricate(:poll_vote, poll: poll, account: Fabricate(:account, username: 'voter'), choice: 0)

    subject.call(status, account.id, text: 'original text', poll: { options: %w(One Three), multiple: false, expires_in: 2.days.to_i })

    expect(poll.reload.options).to eq %w(One Three)
    expect(poll.votes).to be_empty
    expect(status.edits.last.poll_options).to eq %w(One Three)

    subject.call(status, account.id, text: 'original text', poll: nil)

    expect(status.reload.poll_id).to be_nil
    expect(Poll.find_by(id: poll.id)).to be_nil
  end

  it 'does not send ActivityPub for a personal status' do
    status.update!(visibility: :personal)

    subject.call(status, account.id, text: 'edited personal')

    expect(DistributionWorker).to have_received(:perform_async).with(status.id, { 'update' => true })
    expect(ActivityPub::StatusUpdateDistributionWorker).not_to have_received(:perform_async)
  end

  def unprocessed_media(owner, description)
    MediaAttachment.new(
      account: owner,
      type: :image,
      file_file_name: 'test.jpg',
      file_content_type: 'image/jpeg',
      file_file_size: 1,
      description: description
    ).tap { |media| media.save!(validate: false) }
  end
end
