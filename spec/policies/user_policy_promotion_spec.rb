# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPolicy do
  def user_with_role(role)
    user = Fabricate(:user, admin: false, moderator: false)
    user.update_columns(role_id: role.id)
    user
  end

  describe 'legacy promote elevation' do
    let(:admin_role) { UserRole.find_by!(name: 'Admin') }

    it 'allows the default Admin role to promote Everyone to Moderator' do
      actor = user_with_role(admin_role)
      target = Fabricate(:user, admin: false, moderator: false)

      expect(described_class.new(actor.account, target).promote?).to be true
    end

    it 'refuses to let the default Admin role promote Moderator to Owner' do
      actor = user_with_role(admin_role)
      target = Fabricate(:user, admin: false, moderator: true)

      expect(described_class.new(actor.account, target).promote?).to be false
    end

    it 'allows Owner to promote Moderator to Owner' do
      actor = Fabricate(:user, admin: true, moderator: false)
      target = Fabricate(:user, admin: false, moderator: true)

      expect(described_class.new(actor.account, target).promote?).to be true
    end

    it 'allows a position 50 manage_roles role to promote Everyone to Moderator' do
      role = UserRole.create!(name: 'Limited roles low', position: 50, permissions_as_keys: %w(manage_roles))
      actor = user_with_role(role)
      target = Fabricate(:user, admin: false, moderator: false)

      expect(described_class.new(actor.account, target).promote?).to be true
    end

    it 'refuses to let a position 50 manage_roles role promote Moderator to Owner' do
      role = UserRole.create!(name: 'Limited roles high', position: 50, permissions_as_keys: %w(manage_roles))
      actor = user_with_role(role)
      target = Fabricate(:user, admin: false, moderator: true)

      expect(described_class.new(actor.account, target).promote?).to be false
    end

    it 'refuses legacy promote when the target holds the default Admin role' do
      actor = Fabricate(:user, admin: true, moderator: false)
      target = user_with_role(admin_role)

      expect(described_class.new(actor.account, target).promote?).to be false
    end

    it 'refuses legacy promote when the target holds a custom role' do
      custom = UserRole.create!(name: 'Custom target', position: 15, permissions_as_keys: %w(manage_reports))
      actor = Fabricate(:user, admin: true, moderator: false)
      target = user_with_role(custom)

      expect(target.admin).to be false
      expect(target.moderator).to be false
      expect(described_class.new(actor.account, target).promote?).to be false
    end
  end
end
