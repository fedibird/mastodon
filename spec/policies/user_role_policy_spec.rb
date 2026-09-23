# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserRolePolicy do
  def user_with_role(role)
    user = Fabricate(:user, admin: false, moderator: false)
    user.update_columns(role_id: role.id)
    user
  end

  def policy(actor, record)
    described_class.new(actor.account, record)
  end

  let(:owner) { Fabricate(:user, admin: true) }
  let(:admin_role) { UserRole.find_by!(name: 'Admin') }
  let(:admin_actor) { user_with_role(admin_role) }
  let(:custom) { UserRole.create!(name: 'Policy custom', position: 20, permissions_as_keys: %w(invite_users)) }

  describe 'access' do
    it 'allows index and create with manage_roles' do
      expect(policy(admin_actor, UserRole).index?).to be true
      expect(policy(admin_actor, UserRole).create?).to be true
    end

    it 'forbids index and create without manage_roles' do
      actor = user_with_role(UserRole.find_by!(name: 'Moderator'))

      expect(policy(actor, UserRole).index?).to be false
      expect(policy(actor, UserRole).create?).to be false
    end
  end

  describe 'update?' do
    it 'allows a lower role and the actor role' do
      expect(policy(admin_actor, custom).update?).to be true
      expect(policy(admin_actor, admin_role).update?).to be true
    end

    it 'refuses a peer or higher role' do
      peer = UserRole.create!(name: 'Policy peer', position: admin_role.position, permissions_as_keys: %w(invite_users))

      expect(policy(admin_actor, peer).update?).to be false
      expect(policy(admin_actor, UserRole.find_by!(name: 'Owner')).update?).to be false
    end
  end

  describe 'destroy?' do
    it 'allows a lower custom role' do
      expect(policy(owner, custom).destroy?).to be true
    end

    it 'refuses Everyone, Owner, Admin, Moderator, the actor role, and a peer or higher role' do
      peer = UserRole.create!(name: 'Policy peer delete', position: 1000, permissions_as_keys: %w(invite_users))

      expect(policy(owner, UserRole.everyone).destroy?).to be false
      expect(policy(owner, UserRole.find_by!(name: 'Owner')).destroy?).to be false
      expect(policy(owner, admin_role).destroy?).to be false
      expect(policy(owner, UserRole.find_by!(name: 'Moderator')).destroy?).to be false
      expect(policy(owner, owner.user_role).destroy?).to be false
      expect(policy(owner, peer).destroy?).to be false
    end
  end
end
