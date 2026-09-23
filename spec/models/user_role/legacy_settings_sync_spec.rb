# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserRole::LegacySettingsSync do # rubocop:disable Metrics/BlockLength
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  def roles
    {
      everyone: UserRole.find_by!(id: -99),
      moderator: UserRole.find_by!(name: 'Moderator'),
      admin: UserRole.find_by!(name: 'Admin'),
      owner: UserRole.find_by!(name: 'Owner'),
    }
  end

  def invite_bit?(role)
    flag = UserRole::FLAGS[:invite_users]
    role.permissions & flag == flag
  end

  def sync(**options)
    defaults = { min_invite_role: 'admin', show_staff_badge: true, show_moderator_badge: true }
    described_class.call(**defaults.merge(options))
  end

  describe 'min_invite_role' do
    it 'grants invite_users to Everyone and lets Moderator and Admin inherit it for user' do
      sync(min_invite_role: 'user')

      current = roles
      expect(invite_bit?(current[:everyone])).to be true
      expect(current[:everyone].can?(:invite_users)).to be true
      expect(invite_bit?(current[:moderator])).to be false
      expect(current[:moderator].can?(:invite_users)).to be true
      expect(invite_bit?(current[:admin])).to be false
      expect(current[:admin].can?(:invite_users)).to be true
    end

    it 'grants invite_users to Moderator and Admin when the minimum is moderator' do
      sync(min_invite_role: 'moderator')

      current = roles
      expect(invite_bit?(current[:everyone])).to be false
      expect(current[:everyone].can?(:invite_users)).to be false
      expect(invite_bit?(current[:moderator])).to be true
      expect(current[:moderator].can?(:invite_users)).to be true
      expect(invite_bit?(current[:admin])).to be true
      expect(current[:admin].can?(:invite_users)).to be true
    end

    it 'grants invite_users only to Admin when the minimum is admin' do
      sync(min_invite_role: 'admin')

      current = roles
      expect(invite_bit?(current[:everyone])).to be false
      expect(current[:everyone].can?(:invite_users)).to be false
      expect(invite_bit?(current[:moderator])).to be false
      expect(current[:moderator].can?(:invite_users)).to be false
      expect(invite_bit?(current[:admin])).to be true
      expect(current[:admin].can?(:invite_users)).to be true
    end

    # Owner#can?(:invite_users) stays true because administrator expands computed
    # permissions to every flag. min_invite_role == "disabled" still means nobody,
    # including admins, may invite. #165 must keep
    # `return false if Setting.min_invite_role == 'disabled'` when InvitePolicy
    # starts reading roles. This sync does not change InvitePolicy.
    it 'clears invite_users on Everyone, Moderator, and Admin when invites are disabled' do
      sync(min_invite_role: 'disabled')

      current = roles
      expect(invite_bit?(current[:everyone])).to be false
      expect(current[:everyone].can?(:invite_users)).to be false
      expect(invite_bit?(current[:moderator])).to be false
      expect(current[:moderator].can?(:invite_users)).to be false
      expect(invite_bit?(current[:admin])).to be false
      expect(current[:admin].can?(:invite_users)).to be false
      expect(current[:owner].can?(:invite_users)).to be true
      expect(current[:owner].permissions_as_keys).to eq %w(administrator)
    end
  end

  describe 'badges' do
    it 'highlights only Moderator when the staff badge is off and the moderator badge is on' do
      sync(show_staff_badge: false, show_moderator_badge: true)

      current = roles
      expect(current[:owner].highlighted).to be false
      expect(current[:admin].highlighted).to be false
      expect(current[:moderator].highlighted).to be true
      expect(current[:everyone].highlighted).to be false
    end

    it 'highlights Owner and Admin when the staff badge is on and the moderator badge is off' do
      sync(show_staff_badge: true, show_moderator_badge: false)

      current = roles
      expect(current[:owner].highlighted).to be true
      expect(current[:admin].highlighted).to be true
      expect(current[:moderator].highlighted).to be false
      expect(current[:everyone].highlighted).to be false
    end
  end

  it 'leaves a custom role permissions and highlighted flag unchanged' do
    helper = UserRole.create!(name: 'Helper', permissions_as_keys: %w(manage_reports invite_users), highlighted: true)
    permissions = helper.permissions

    sync(min_invite_role: 'disabled', show_staff_badge: false, show_moderator_badge: false)
    helper.reload

    expect(helper.permissions).to eq permissions
    expect(helper.highlighted).to be true
    expect(helper.can?(:manage_reports)).to be true
    expect(helper.can?(:invite_users)).to be true
  end

  it 'keeps unrelated permission bits and is idempotent' do
    moderator = UserRole.find_by!(name: 'Moderator')
    moderator.update!(permissions: moderator.permissions | UserRole::FLAGS[:invite_users])
    preserved = moderator.permissions & ~UserRole::FLAGS[:invite_users]
    count = UserRole.count

    2.times { sync(min_invite_role: 'admin', show_staff_badge: true, show_moderator_badge: true) }

    moderator.reload
    expect(moderator.permissions).to eq preserved
    expect(moderator.can?(:manage_reports)).to be true
    expect(invite_bit?(moderator)).to be false
    expect(UserRole.count).to eq count
    expect(roles[:admin].can?(:invite_users)).to be true
  end

  it 'raises when a default role is missing' do
    UserRole.where(name: 'Moderator').delete_all

    expect { sync }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'raises for an unsupported min_invite_role before writing' do
    before = roles.transform_values(&:permissions)

    expect { sync(min_invite_role: 'else') }.to raise_error(ArgumentError, /Unsupported min_invite_role/)
    expect(roles.transform_values(&:permissions)).to eq before
  end
end
