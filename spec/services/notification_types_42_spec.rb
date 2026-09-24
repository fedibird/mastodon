# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Mastodon 4.2 notification types', type: :service do
  def role_with(*permissions)
    UserRole.create!(name: "Notify #{permissions.join}", permissions_as_keys: permissions.map(&:to_s), position: 10)
  end

  def staff_user(role)
    user = Fabricate(:user)
    user.update!(role_id: role.id)
    user
  end

  describe Notification do
    it 'accepts the new types and the existing Fedibird types' do
      expect(Notification::TYPES).to include(:update, :'admin.sign_up', :'admin.report', :emoji_reaction, :status_reference, :scheduled_status, :followed)
    end

    it 'sets from_account from the edited status' do
      status = Fabricate(:status)
      notification = Notification.create!(account: Fabricate(:account), type: :update, activity: status)

      expect(notification.from_account).to eq status.account
      expect(notification.target_status).to eq status
    end

    it 'sets from_account to the signed-up account' do
      account = Fabricate(:account)
      notification = Notification.create!(account: Fabricate(:account), type: :'admin.sign_up', activity: account)

      expect(notification.from_account).to eq account
    end

    it 'sets from_account to the reporter and preloads the report target' do
      report = Fabricate(:report)
      notification = Notification.create!(account: Fabricate(:account), type: :'admin.report', activity: report)
      loaded = Notification.where(id: notification.id).to_a
      Notification.preload_cache_collection_target_statuses(loaded) { |statuses| statuses }

      expect(notification.from_account).to eq report.account
      expect(loaded.first.association(:report).loaded?).to be true
      expect(loaded.first.report.association(:target_account).loaded?).to be true
    end
  end

  describe FanOutOnWriteService do
    let(:status) { Fabricate(:status, visibility: :public) }
    let(:booster) { Fabricate(:user).account }
    let(:remote_booster) { Fabricate(:account, domain: 'boost.example', username: 'remote') }
    let(:bystander) { Fabricate(:user).account }

    before do
      Fabricate(:status, account: booster, reblog: status)
      Fabricate(:status, account: remote_booster, reblog: status)
    end

    it 'notifies local boosters when a status is edited' do
      described_class.new.call(status, update: true)

      expect(Notification.where(account: booster, type: 'update', activity: status)).to exist
      expect(Notification.where(account: remote_booster, type: 'update')).not_to exist
      expect(Notification.where(account: bystander, type: 'update')).not_to exist
    end

    it 'does not notify boosters on the original distribution' do
      described_class.new.call(status, update: false)

      expect(Notification.where(type: 'update', activity: status)).not_to exist
    end
  end

  describe ReportService do
    let(:role) { role_with(:manage_reports) }
    let(:reporter) { Fabricate(:user).account }
    let(:target) { Fabricate(:account) }

    it 'notifies a functional manage_reports user even when report email is off' do
      staff = staff_user(role)
      staff.settings.notification_emails = staff.settings.notification_emails.merge('report' => false)
      staff.save!

      expect(AdminMailer).not_to receive(:new_report)

      report = described_class.new.call(reporter, target)

      expect(Notification.where(account: staff.account, type: 'admin.report', activity: report)).to exist
    end

    it 'also sends the existing report email when it is enabled' do
      staff = staff_user(role)
      staff.settings.notification_emails = staff.settings.notification_emails.merge('report' => true)
      staff.save!
      mail = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
      allow(AdminMailer).to receive(:new_report).and_return(mail)

      report = described_class.new.call(reporter, target)

      expect(AdminMailer).to have_received(:new_report).with(staff.account, report)
      expect(Notification.where(account: staff.account, type: 'admin.report', activity: report)).to exist
    end

    it 'skips users without manage_reports and non-functional staff' do
      outsider = Fabricate(:user)
      disabled = staff_user(role)
      disabled.update!(disabled: true)

      report = described_class.new.call(reporter, target)

      expect(Notification.where(account_id: [outsider.account_id, disabled.account_id], activity: report)).not_to exist
    end
  end

  describe BootstrapTimelineService do
    let(:role) { role_with(:manage_users) }
    let(:signup) { Fabricate(:account) }

    it 'notifies a functional manage_users user' do
      staff = staff_user(role)

      described_class.new.call(signup)

      notification = Notification.find_by!(account: staff.account, type: 'admin.sign_up')
      expect(notification.activity).to eq signup
      expect(notification.from_account).to eq signup
    end

    it 'skips users without manage_users and non-functional staff' do
      outsider = Fabricate(:user)
      disabled = staff_user(role)
      disabled.update!(disabled: true)

      described_class.new.call(signup)

      expect(Notification.where(account_id: [outsider.account_id, disabled.account_id], type: 'admin.sign_up')).not_to exist
    end
  end

  describe Web::NotificationSerializer do
    it 'resolves titles for the new types without a nil body' do
      status = Fabricate(:status, text: 'edited body')
      update = Fabricate(:notification, activity: status, type: :update, from_account: status.account)
      signup = Fabricate(:account, username: 'newbie', note: 'hello')
      sign_up = Fabricate(:notification, activity: signup, type: :'admin.sign_up', from_account: signup)
      report = Fabricate(:report)
      admin_report = Fabricate(:notification, activity: report, type: :'admin.report', from_account: report.account)

      [update, sign_up, admin_report].each do |notification|
        serializer = described_class.new(notification)
        expect(serializer.title).to be_present
        expect(serializer.body).to be_a(String)
      end

      I18n.with_locale(:ja) do
        expect(Web::NotificationSerializer.new(update).title).to include('編集')
      end
    end
  end

  describe NotifyService do
    it 'does not send NotificationMailer for update, admin.sign_up, or admin.report' do
      recipient = Fabricate(:user)
      recipient.settings.notification_emails = recipient.settings.notification_emails.merge(
        'update' => true,
        'admin.sign_up' => true,
        'admin.report' => true
      )
      recipient.save!
      status = Fabricate(:status)
      report = Fabricate(:report)

      expect(NotificationMailer).not_to receive(:public_send)

      described_class.new.call(recipient.account, :update, status)
      described_class.new.call(recipient.account, :'admin.sign_up', Fabricate(:account))
      described_class.new.call(recipient.account, :'admin.report', report)
    end
  end
end
