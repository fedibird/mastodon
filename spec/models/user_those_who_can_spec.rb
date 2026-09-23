# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User, '.those_who_can' do
  let!(:owner) { user_with_role('Owner') }
  let!(:moderator) { user_with_role('Moderator') }
  let!(:ordinary) { Fabricate(:user, admin: false, moderator: false) }

  it 'matches explicit roles for manage_users and manage_reports, not Everyone' do
    reports = UserRole.create!(name: 'Reporter', position: 15, permissions_as_keys: %w(manage_reports))
    reporter = Fabricate(:user, admin: false, moderator: false)
    reporter.update_columns(role_id: reports.id)

    expect(User.those_who_can(:manage_users)).to include(owner, moderator)
    expect(User.those_who_can(:manage_users)).not_to include(ordinary, reporter)
    expect(User.those_who_can(:manage_reports)).to include(owner, moderator, reporter)
    expect(User.those_who_can(:manage_reports)).not_to include(ordinary)
  end

  it 'includes role_id nil users when Everyone has the permission' do
    UserRole.everyone.update!(permissions: UserRole::FLAGS[:invite_users])

    expect(User.those_who_can(:invite_users)).to include(ordinary, owner)
  end

  it 'skips a non-functional role holder when notifying staff about a pending account' do
    disabled = user_with_role('Moderator')
    disabled.update_columns(disabled: true)
    pending = Fabricate(:user, approved: false)
    mail = instance_double(ActionMailer::MessageDelivery, deliver_later: true)

    allow(AdminMailer).to receive(:new_pending_account).and_return(mail)
    expect(AdminMailer).to receive(:new_pending_account).with(owner.account, pending).and_return(mail)
    expect(AdminMailer).to receive(:new_pending_account).with(moderator.account, pending).and_return(mail)
    expect(AdminMailer).not_to receive(:new_pending_account).with(disabled.account, pending)
    expect(AdminMailer).not_to receive(:new_pending_account).with(ordinary.account, pending)

    pending.send(:notify_staff_about_pending_account!)
  end
end
