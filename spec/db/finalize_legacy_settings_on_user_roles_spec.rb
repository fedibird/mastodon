# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db', 'post_migrate', '20260923120000_finalize_legacy_settings_on_user_roles.rb')

RSpec.describe FinalizeLegacySettingsOnUserRoles, type: :model do
  around do |example|
    previous = Setting.min_invite_role
    example.run
  ensure
    Setting.min_invite_role = previous
    Setting.where(var: %w(show_staff_badge show_moderator_badge)).delete_all
    Rails.cache.clear
  end

  def write_badge_setting(var, value)
    Setting.where(var: var, thing_type: nil, thing_id: nil).delete_all
    Setting.insert!({ var: var, value: YAML.dump(value), thing_type: nil, thing_id: nil, created_at: Time.current, updated_at: Time.current })
  end

  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  def invite_bit?(role)
    flag = UserRole::FLAGS[:invite_users]
    role.reload.permissions & flag == flag
  end

  it 'copies stored settings onto the default roles and can run twice' do
    Setting.min_invite_role = 'moderator'
    write_badge_setting('show_staff_badge', false)
    write_badge_setting('show_moderator_badge', true)
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
    write_badge_setting('show_staff_badge', true)
    write_badge_setting('show_moderator_badge', true)
    UserRole.find_by!(name: 'Admin').update!(permissions: UserRole.find_by!(name: 'Admin').permissions | UserRole::FLAGS[:invite_users])

    described_class.new.up

    expect(UserRole.everyone.can?(:invite_users)).to be false
    expect(UserRole.find_by!(name: 'Moderator').can?(:invite_users)).to be false
    expect(UserRole.find_by!(name: 'Admin').can?(:invite_users)).to be false
    expect(UserRole.find_by!(name: 'Owner').can?(:invite_users)).to be true
    expect(InvitePolicy.new(user_with_role('Owner').account, Invite).create?).to be true
    expect(InvitePolicy.new(Fabricate(:user, admin: false, moderator: false).account, Invite).create?).to be false
  end

  it 'hides the moderator badge when that legacy setting is false' do
    Setting.min_invite_role = 'admin'
    write_badge_setting('show_staff_badge', true)
    write_badge_setting('show_moderator_badge', false)

    described_class.new.up

    expect(UserRole.find_by!(name: 'Moderator').highlighted).to be false
    expect(UserRole.find_by!(name: 'Admin').highlighted).to be true
    expect(UserRole.find_by!(name: 'Owner').highlighted).to be true
  end

  it 'treats missing badge settings as shown and does not raise' do
    Setting.min_invite_role = 'admin'
    Setting.where(var: %w(show_staff_badge show_moderator_badge)).delete_all
    UserRole.find_by!(name: 'Admin').update!(highlighted: false)
    UserRole.find_by!(name: 'Owner').update!(highlighted: false)
    UserRole.find_by!(name: 'Moderator').update!(highlighted: false)

    expect { described_class.new.up }.not_to raise_error

    expect(UserRole.find_by!(name: 'Admin').highlighted).to be true
    expect(UserRole.find_by!(name: 'Owner').highlighted).to be true
    expect(UserRole.find_by!(name: 'Moderator').highlighted).to be true
  end
end
