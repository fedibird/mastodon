# frozen_string_literal: true

require 'rails_helper'

describe LocalNotificationWorker do
  let(:receiver) { Fabricate(:user).account }
  let(:status) { Fabricate(:status) }

  it 'creates an update notification' do
    described_class.new.perform(receiver.id, status.id, 'Status', 'update')

    notification = Notification.find_by!(account: receiver, type: 'update')
    expect(notification.activity).to eq status
    expect(notification.from_account).to eq status.account
  end

  it 'replaces the previous update notification for the same status' do
    described_class.new.perform(receiver.id, status.id, 'Status', 'update')
    first_id = Notification.find_by!(account: receiver, type: 'update').id

    described_class.new.perform(receiver.id, status.id, 'Status', 'update')

    updates = Notification.where(account: receiver, type: 'update')
    expect(updates.count).to eq 1
    expect(updates.first.id).not_to eq first_id
  end

  it 'leaves other notification types in place' do
    mention = Fabricate(:mention, account: receiver, status: Fabricate(:status))
    other = Fabricate(:notification, account: receiver, activity: mention, type: :mention)

    described_class.new.perform(receiver.id, status.id, 'Status', 'update')

    expect(Notification.find_by(id: other.id)).to eq other
  end
end
