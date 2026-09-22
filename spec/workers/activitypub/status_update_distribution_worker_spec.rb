# frozen_string_literal: true

require 'rails_helper'

describe ActivityPub::StatusUpdateDistributionWorker do
  subject { described_class.new }

  let(:status) { Fabricate(:status, text: 'edited body', visibility: :public) }
  let(:follower) { Fabricate(:account, protocol: :activitypub, inbox_url: 'http://example.com/inbox') }
  let(:payloads) { [] }

  before do
    status.update!(edited_at: Time.utc(2026, 9, 22, 12, 0, 0))
    follower.follow!(status.account)
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk) do |inboxes, &block|
      inboxes.each { |inbox| payloads << block.call(inbox) }
    end
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
  end

  it 'delivers an Update activity whose object keeps quote extensions' do
    quoted = Fabricate(:status, visibility: :public, text: 'quoted')
    status.update!(quote_id: quoted.id, edited_at: Time.utc(2026, 9, 22, 12, 0, 0))

    subject.perform(status.id)

    expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['http://example.com/inbox'])
    json = Oj.load(payloads.first.first)
    expect(json['type']).to eq 'Update'
    expect(json['id']).to eq "#{ActivityPub::TagManager.instance.uri_for(status)}#updates/#{status.edited_at.to_i}"
    expect(json['published']).to eq status.edited_at.iso8601
    expect(json['object']['updated']).to eq status.edited_at.iso8601
    expect(json['object']['quoteUri']).to eq ActivityPub::TagManager.instance.uri_for(quoted)
  end

  it 'does not deliver a personal status' do
    status.update!(visibility: :personal)

    subject.perform(status.id)

    expect(ActivityPub::DeliveryWorker).not_to have_received(:push_bulk)
  end

  it 'does not deliver a direct status' do
    status.update!(visibility: :direct)

    subject.perform(status.id)

    expect(ActivityPub::DeliveryWorker).not_to have_received(:push_bulk)
  end
end
