# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityPub::OrderedReboostDeliveryWorker do
  let(:account) { Fabricate(:account) }
  let(:original) { Fabricate(:status, account: account) }
  let(:boost) { Fabricate(:status, account: account, reblog: original) }
  let(:operation) do
    ReboostOperation.create!(
      account: account,
      reblog_of_id: original.id,
      old_status_id: 1,
      new_status_id: boost.id,
      state: 'federating',
      reboost: true,
      undo_payload: '{"type":"Undo"}',
      undo_inboxes: ['https://remote.example/inbox']
    )
  end

  it 'attempts Undo before Announce on the same inbox' do
    order = []
    delivery = instance_double(ActivityPub::DeliveryWorker)
    allow(ActivityPub::DeliveryWorker).to receive(:new).and_return(delivery)
    allow(delivery).to receive(:perform) do |json, _account_id, inbox|
      order << [json.include?('Undo') ? :undo : :announce, inbox]
      true
    end

    described_class.new.perform(operation.id, 'https://remote.example/inbox')

    expect(order.map(&:first)).to eq [:undo, :announce]
    expect(order.map(&:last).uniq).to eq ['https://remote.example/inbox']
  end

  it 'retries Undo before Announce on this inbox when the Undo delivery fails' do
    delivery = instance_double(ActivityPub::DeliveryWorker)
    allow(ActivityPub::DeliveryWorker).to receive(:new).and_return(delivery)
    calls = 0
    allow(delivery).to receive(:perform) do
      calls += 1
      raise Mastodon::UnexpectedResponseError if calls == 1
    end
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)

    expect { described_class.new.perform(operation.id, 'https://remote.example/inbox') }.to raise_error(Mastodon::UnexpectedResponseError)

    expect(ActivityPub::DeliveryWorker).not_to have_received(:perform_async)
    expect(calls).to eq 1
  end

  it 'retries the inbox when Announce delivery is suppressed' do
    delivery = instance_double(ActivityPub::DeliveryWorker)
    allow(ActivityPub::DeliveryWorker).to receive(:new).and_return(delivery)
    calls = 0
    allow(delivery).to receive(:perform) do
      calls += 1
      calls == 1
    end

    expect { described_class.new.perform(operation.id, 'https://remote.example/inbox') }.to raise_error(described_class::AnnounceNotDelivered)

    expect(calls).to eq 2
  end

  it 'does not announce when Undo delivery is suppressed' do
    delivery = instance_double(ActivityPub::DeliveryWorker)
    allow(ActivityPub::DeliveryWorker).to receive(:new).and_return(delivery)
    allow(delivery).to receive(:perform).and_return(false)

    expect { described_class.new.perform(operation.id, 'https://remote.example/inbox') }.to raise_error(described_class::UndoNotDelivered)

    expect(delivery).to have_received(:perform).once
  end

  it 'does not announce after Undo when the replacement was removed' do
    boost.discard
    delivery = instance_double(ActivityPub::DeliveryWorker)
    allow(ActivityPub::DeliveryWorker).to receive(:new).and_return(delivery)
    allow(delivery).to receive(:perform).and_return(true)

    described_class.new.perform(operation.id, 'https://remote.example/inbox')

    expect(delivery).to have_received(:perform).once.with('{"type":"Undo"}', account.id, 'https://remote.example/inbox')
  end

  it 'does not announce a cancelled replacement' do
    operation.update!(state: 'cancelled', error_code: 'unreblogged')
    delivery = instance_double(ActivityPub::DeliveryWorker)
    allow(ActivityPub::DeliveryWorker).to receive(:new).and_return(delivery)
    allow(delivery).to receive(:perform).and_return(true)

    described_class.new.perform(operation.id, 'https://other.example/inbox')

    expect(delivery).to have_received(:perform).once.with('{"type":"Undo"}', account.id, 'https://other.example/inbox')
    expect(operation.reload.state).to eq 'cancelled'
  end

  it 'sends the saved Undo when the replacement wrapper is already gone' do
    operation.update!(new_status_id: nil)
    delivery = instance_double(ActivityPub::DeliveryWorker)
    allow(ActivityPub::DeliveryWorker).to receive(:new).and_return(delivery)
    allow(delivery).to receive(:perform).and_return(true)

    described_class.new.perform(operation.id, 'https://remote.example/inbox')

    expect(delivery).to have_received(:perform).once.with('{"type":"Undo"}', account.id, 'https://remote.example/inbox')
  end
end
