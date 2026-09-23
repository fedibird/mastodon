# frozen_string_literal: true

require 'rails_helper'

# Covers the legacy invite and badge fields that Role CRUD must leave unchanged.
# rubocop:disable Metrics/BlockLength
describe Admin::RolesController, type: :controller do
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

  before do
    Setting.min_invite_role = 'admin'
    Setting.show_staff_badge = true
    Setting.show_moderator_badge = true
    UserRole::LegacySettingsSync.call
    sign_in Fabricate(:user, admin: true), scope: :user
  end

  def invite_bit?(role)
    flag = UserRole::FLAGS[:invite_users]
    role.permissions & flag == flag
  end

  it 'does not add invite_users to Moderator from a direct Role update' do
    moderator = UserRole.find_by!(name: 'Moderator')
    expect(invite_bit?(moderator)).to be false

    patch :update, params: {
      id: moderator.id,
      user_role: { color: '#222222', permissions_as_keys: moderator.permissions_as_keys + ['invite_users'] },
    }

    expect(response).to redirect_to(admin_roles_path)
    moderator.reload
    expect(invite_bit?(moderator)).to be false
    expect(moderator.color).to eq '#222222'
    expect(moderator.can?(:manage_reports)).to be true
  end

  it 'does not remove invite_users from Admin' do
    admin = UserRole.find_by!(name: 'Admin')
    expect(invite_bit?(admin)).to be true

    patch :update, params: {
      id: admin.id,
      user_role: { color: '#111111', permissions_as_keys: admin.permissions_as_keys - ['invite_users'] },
    }

    expect(response).to redirect_to(admin_roles_path)
    admin.reload
    expect(invite_bit?(admin)).to be true
    expect(admin.color).to eq '#111111'
    expect(admin.can?(:manage_roles)).to be true
  end

  it 'does not change Everyone invite_users or highlighted from Role CRUD' do
    everyone = UserRole.everyone
    expect(invite_bit?(everyone)).to be false

    patch :update, params: {
      id: everyone.id,
      user_role: { color: '#333333', highlighted: '1', permissions_as_keys: ['invite_users'] },
    }

    expect(response).to redirect_to(admin_roles_path)
    everyone.reload
    expect(invite_bit?(everyone)).to be false
    expect(everyone.highlighted).to be false
    expect(everyone.color).to eq '#333333'
  end

  it 'allows invite_users and highlighted changes on a custom role' do
    role = UserRole.create!(name: 'Legacy free', position: 12, permissions_as_keys: %w(manage_reports), highlighted: false)

    patch :update, params: {
      id: role.id,
      user_role: { permissions_as_keys: %w(manage_reports invite_users), highlighted: '1' },
    }

    expect(response).to redirect_to(admin_roles_path)
    role.reload
    expect(invite_bit?(role)).to be true
    expect(role.highlighted).to be true
  end

  it 'does not change highlighted on Owner, Admin, or Moderator' do
    %w(Owner Admin Moderator).each do |name|
      role = UserRole.find_by!(name: name)
      expect(role.highlighted).to be true

      patch :update, params: { id: role.id, user_role: { highlighted: '0', color: '#444444' } }

      expect(response).to redirect_to(admin_roles_path)
      role.reload
      expect(role.highlighted).to be true
      expect(role.color).to eq '#444444'
    end
  end

  it 'still lets LegacySettingsSync change invite bits and highlighted' do
    Setting.min_invite_role = 'user'
    Setting.show_staff_badge = false
    Setting.show_moderator_badge = true
    UserRole::LegacySettingsSync.call

    everyone = UserRole.find_by!(id: -99)
    moderator = UserRole.find_by!(name: 'Moderator')
    admin = UserRole.find_by!(name: 'Admin')
    owner = UserRole.find_by!(name: 'Owner')

    expect(invite_bit?(everyone)).to be true
    expect(invite_bit?(moderator)).to be false
    expect(moderator.can?(:invite_users)).to be true
    expect(invite_bit?(admin)).to be false
    expect(admin.can?(:invite_users)).to be true
    expect(everyone.highlighted).to be false
    expect(moderator.highlighted).to be true
    expect(admin.highlighted).to be false
    expect(owner.highlighted).to be false
  end

  it 'lets the sync flag override a Role CRUD lock on the same instance' do
    moderator = UserRole.find_by!(name: 'Moderator')
    moderator.enforce_legacy_managed_fields!
    moderator.allow_legacy_settings_sync!
    moderator.permissions_as_keys = moderator.permissions_as_keys + ['invite_users']
    moderator.highlighted = false

    expect(moderator.save).to be true
    moderator.reload
    expect(invite_bit?(moderator)).to be true
    expect(moderator.highlighted).to be false
  end
end
# rubocop:enable Metrics/BlockLength
