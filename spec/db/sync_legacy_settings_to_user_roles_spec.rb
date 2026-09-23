# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db', 'post_migrate', '20260923050000_sync_legacy_settings_to_user_roles.rb')

RSpec.describe SyncLegacySettingsToUserRoles, type: :model do # rubocop:disable Metrics/BlockLength
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

  it 'copies the prepared legacy settings onto the default roles and can run twice' do
    Setting.min_invite_role = 'user'
    Setting.show_staff_badge = false
    Setting.show_moderator_badge = true
    UserRole.find_by!(id: -99).update!(permissions: 0, highlighted: true)
    UserRole.find_by!(name: 'Moderator').update!(permissions: UserRole::FLAGS[:manage_reports], highlighted: false)
    UserRole.find_by!(name: 'Admin').update!(permissions: UserRole::FLAGS[:manage_reports] | UserRole::FLAGS[:invite_users], highlighted: true)
    count = UserRole.count

    described_class.new.up
    described_class.new.up

    everyone = UserRole.find_by!(id: -99)
    moderator = UserRole.find_by!(name: 'Moderator')
    admin = UserRole.find_by!(name: 'Admin')
    owner = UserRole.find_by!(name: 'Owner')

    expect(invite_bit?(everyone)).to be true
    expect(everyone.can?(:invite_users)).to be true
    expect(everyone.highlighted).to be false
    expect(invite_bit?(moderator)).to be false
    expect(moderator.can?(:invite_users)).to be true
    expect(moderator.can?(:manage_reports)).to be true
    expect(moderator.highlighted).to be true
    expect(invite_bit?(admin)).to be false
    expect(admin.can?(:invite_users)).to be true
    expect(admin.can?(:manage_reports)).to be true
    expect(admin.highlighted).to be false
    expect(owner.highlighted).to be false
    expect(owner.can?(:invite_users)).to be true
    expect(UserRole.count).to eq count
  end

  it 'does not restore role state on the way down' do
    Setting.min_invite_role = 'disabled'
    Setting.show_staff_badge = false
    Setting.show_moderator_badge = false
    described_class.new.up

    highlighted = UserRole.find_by!(name: 'Admin').highlighted
    permissions = UserRole.find_by!(name: 'Admin').permissions

    described_class.new.down

    admin = UserRole.find_by!(name: 'Admin')
    expect(admin.highlighted).to eq highlighted
    expect(admin.permissions).to eq permissions
    expect(admin.can?(:invite_users)).to be false
  end
end
