# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reboost::FederationWorker do
  let(:account) { Fabricate(:account) }
  let(:original) { Fabricate(:status, account: account, visibility: 'public') }
  let(:boost) { Fabricate(:status, account: account, reblog: original, visibility: 'public') }
  let(:operation) do
    ReboostOperation.create!(
      account: account,
      reblog_of_id: original.id,
      old_status_id: boost.id,
      new_status_id: boost.id,
      state: 'federating',
      reboost: true,
      undo_payload: '{"type":"Undo"}',
      undo_inboxes: ['https://relay.example/inbox'],
      removal_finished_at: Time.current
    )
  end

  before do
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)
    allow(ActivityPub::OrderedReboostDeliveryWorker).to receive(:push_bulk)
  end

  it 'sends the saved Undo when the replacement wrapper is gone' do
    operation.update!(new_status_id: nil)

    described_class.new.perform(operation.id)

    expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['https://relay.example/inbox'])
    expect(operation.reload.state).to eq 'completed'
    expect(ActivityPub::OrderedReboostDeliveryWorker).not_to have_received(:push_bulk)
  end

  it 'sends only the saved Undo when the operation was cancelled' do
    operation.update!(state: 'cancelled', error_code: 'unreblogged')

    described_class.new.perform(operation.id)

    expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['https://relay.example/inbox'])
    expect(ActivityPub::OrderedReboostDeliveryWorker).not_to have_received(:push_bulk)
    expect(operation.reload).to have_attributes(state: 'completed', error_code: 'unreblogged')
  end

  it 'puts a public relay on the ordered Undo-then-Announce path once' do
    relays = instance_double(ActiveRecord::Relation, pluck: ['https://relay.example/inbox'])
    allow(Relay).to receive(:enabled).and_return(relays)
    worker = described_class.new
    allow(worker).to receive(:announce_targets).and_return([])

    worker.perform(operation.id)

    expect(ActivityPub::OrderedReboostDeliveryWorker).to have_received(:push_bulk).with(['https://relay.example/inbox'])
    expect(ActivityPub::DeliveryWorker).not_to have_received(:push_bulk)
    expect(operation.reload.state).to eq 'completed'
  end
end
