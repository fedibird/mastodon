# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db', 'post_migrate', '20260923120000_finalize_legacy_settings_on_user_roles.rb')

RSpec.describe FinalizeLegacySettingsOnUserRoles, type: :model do
  around do |example|
    previous = {
      min_invite_role: Setting.min_invite_role,
      show_staff_badge: Setting.show_staff_badge,
      show_moderator_badge: Setting.show_moderator_badge,
    }
    example.run
  ensure
    previous.each { |key, value| Setting.public_send("#{key}=", value) }
    Rails.cache.clear
  end

  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  def invite_bit?(role)
    flag = UserRole::FLAGS[:invite_users]
    role.reload.permissions & flag == flag
  end

  it 'copies stored settings onto the default roles and can run twice' do
    Setting.min_invite_role = 'moderator'
    Setting.show_staff_badge = false
    Setting.show_moderator_badge = true
    UserRole.find_by!(id: -99).update!(permissions: UserRole::FLAGS[:invite_users], highlighted: true)

    described_class.new.up
    described_class.new.up

    everyone = UserRole.find_by!(id: -99)
    moderator = UserRole.find_by!(name: 'Moderator')
    admin = UserRole.find_by!(name: 'Admin')
    owner = UserRole.find_by!(name: 'Owner')

    expect(invite_bit?(everyone)).to be false
    expect(everyone.can?(:invite_users)).to be false
    expect(everyone.highlighted).to be false
    expect(invite_bit?(moderator)).to be true
    expect(moderator.highlighted).to be true
    expect(invite_bit?(admin)).to be true
    expect(admin.highlighted).to be false
    expect(owner.highlighted).to be false
    expect(owner.can?(:invite_users)).to be true
  end

  it 'clears invite_users on Everyone, Moderator, and Admin when invites were disabled, and leaves Owner able to invite' do
    Setting.min_invite_role = 'disabled'
    Setting.show_staff_badge = true
    Setting.show_moderator_badge = true
    UserRole.find_by!(name: 'Admin').update!(permissions: UserRole.find_by!(name: 'Admin').permissions | UserRole::FLAGS[:invite_users])

    described_class.new.up

    expect(UserRole.everyone.can?(:invite_users)).to be false
    expect(UserRole.find_by!(name: 'Moderator').can?(:invite_users)).to be false
    expect(UserRole.find_by!(name: 'Admin').can?(:invite_users)).to be false
    expect(UserRole.find_by!(name: 'Owner').can?(:invite_users)).to be true
    expect(InvitePolicy.new(Fabricate(:user, admin: true).account, Invite).create?).to be true
    expect(InvitePolicy.new(Fabricate(:user, admin: false, moderator: false).account, Invite).create?).to be false
  end
end
