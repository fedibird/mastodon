# frozen_string_literal: true

require 'rails_helper'

describe 'webhook event hooks' do
  let(:calls) { [] }

  before do
    allow(TriggerWebhookWorker).to receive(:perform_async) { |*args| calls << args }
  end

  def fired(event, class_name, id)
    calls.select { |fired_event, fired_class, fired_id| fired_event == event && fired_class == class_name && fired_id == id }
  end

  describe Account do
    it 'emits account.updated for a local account' do
      account = Fabricate(:account, username: 'localhook')

      account.update!(display_name: 'Updated')

      expect(fired('account.updated', 'Account', account.id).size).to eq 1
    end

    it 'does not emit account.updated for a remote account' do
      account = Fabricate(:account, username: 'remotehook', domain: 'remote.example', uri: 'https://remote.example/users/remotehook')

      account.update!(display_name: 'Updated')

      expect(fired('account.updated', 'Account', account.id)).to be_empty
    end
  end

  describe User do
    around do |example|
      previous = Setting.registrations_mode
      example.run
      Setting.registrations_mode = previous
    end

    before do
      allow_any_instance_of(User).to receive(:send_devise_notification)
      allow(UserMailer).to receive(:welcome).and_return(double(deliver_later: true))
      allow(BootstrapTimelineWorker).to receive(:perform_async)
    end

    def create_user(username)
      User.create!(
        email: "#{username}@example.com",
        password: '123456789',
        agreement: true,
        account: Fabricate(:account, username: username)
      )
    end

    it 'emits account.created once and account.approved once after open registration confirmation' do
      Setting.registrations_mode = 'open'
      user = create_user('openhook')

      expect(fired('account.created', 'Account', user.account_id).size).to eq 1
      expect(fired('account.approved', 'Account', user.account_id)).to be_empty

      user.confirm

      expect(fired('account.created', 'Account', user.account_id).size).to eq 1
      expect(fired('account.approved', 'Account', user.account_id).size).to eq 1
    end

    it 'emits account.created but not account.approved for an unapproved account' do
      Setting.registrations_mode = 'approved'
      user = create_user('pendinghook')

      expect(user.approved?).to be false
      expect(fired('account.created', 'Account', user.account_id).size).to eq 1
      expect(fired('account.approved', 'Account', user.account_id)).to be_empty
    end

    it 'emits account.approved once when a confirmed pending account is approved' do
      Setting.registrations_mode = 'approved'
      user = create_user('confirmedpending')
      user.confirm

      expect(fired('account.approved', 'Account', user.account_id)).to be_empty

      user.approve!

      expect(fired('account.approved', 'Account', user.account_id).size).to eq 1
    end

    it 'emits account.approved only once when an unconfirmed pending account is approved and then confirmed' do
      Setting.registrations_mode = 'approved'
      user = create_user('unconfirmedpending')

      user.approve!
      expect(user.confirmed?).to be false
      expect(fired('account.approved', 'Account', user.account_id)).to be_empty

      user.confirm

      expect(fired('account.approved', 'Account', user.account_id).size).to eq 1
    end
  end

  describe Report do
    it 'emits report.created and report.updated' do
      report = Fabricate(:report, comment: 'initial')

      expect(fired('report.created', 'Report', report.id).size).to eq 1

      report.update!(comment: 'updated')

      expect(fired('report.updated', 'Report', report.id).size).to eq 1
    end
  end

  describe Status do
    it 'emits status.created and status.updated for a local status' do
      status = Fabricate(:status, text: 'local post')

      expect(fired('status.created', 'Status', status.id).size).to eq 1

      status.update!(text: 'edited local post')

      expect(fired('status.updated', 'Status', status.id).size).to eq 1
    end

    it 'does not emit status webhooks for a remote status' do
      account = Fabricate(:account, domain: 'remote.example', username: 'remotestatus', uri: 'https://remote.example/users/remotestatus')
      status = Fabricate(:status, account: account, text: 'remote post')

      expect(fired('status.created', 'Status', status.id)).to be_empty

      status.update!(text: 'edited remote post')

      expect(fired('status.updated', 'Status', status.id)).to be_empty
    end
  end
end
