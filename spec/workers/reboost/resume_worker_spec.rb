# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reboost::ResumeWorker do
  let(:user) { Fabricate(:user, current_sign_in_at: Time.now.utc) }
  let(:account) { user.account }
  let(:original) { Fabricate(:status, account: account) }
  let(:operation) do
    ReboostOperation.create!(
      account: account,
      reblog_of_id: original.id,
      state: 'pending',
      reboost: true,
      undo_payload: '{"type":"Undo"}',
      undo_inboxes: ['https://remote.example/inbox'],
      options: {}
    )
  end

  before do
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)
  end

  it 'delivers a saved Undo when the cooldown rejects the resume' do
    allow(Reboost::Placement).to receive(:resume!).and_raise(Mastodon::ReboostCooldownError.new(12))

    described_class.new.perform(operation.id)

    expect(operation.reload).to have_attributes(state: 'failed', error_code: 'cooldown')
    expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['https://remote.example/inbox'])
  end

  it 'leaves a cooldown failure without delivery when no Undo was saved' do
    operation.update!(undo_payload: nil)
    allow(Reboost::Placement).to receive(:resume!).and_raise(Mastodon::ReboostCooldownError.new(12))

    described_class.new.perform(operation.id)

    expect(operation.reload).to have_attributes(state: 'failed', error_code: 'cooldown')
    expect(ActivityPub::DeliveryWorker).not_to have_received(:push_bulk)
  end

  it 'delivers a saved Undo when the original status is gone' do
    allow(Status).to receive(:find_by).and_call_original
    allow(Status).to receive(:find_by).with(id: original.id).and_return(nil)

    described_class.new.perform(operation.id)

    expect(operation.reload).to have_attributes(state: 'failed', error_code: 'missing_status')
    expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['https://remote.example/inbox'])
  end

  it 'delivers a saved Undo when reboost is turned off before resume' do
    user.settings.enable_reboost = false
    user.save!

    described_class.new.perform(operation.id)

    expect(operation.reload.error_code).to eq 'reboost_disabled'
    expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['https://remote.example/inbox'])
  end
end
