# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User, type: :model do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:owner_role) { UserRole.find_by!(name: 'Owner') }
  let(:moderator_role) { UserRole.find_by!(name: 'Moderator') }
  let(:admin_role) { UserRole.find_by!(name: 'Admin') }

  describe 'legacy boolean dual-write' do
    it 'stores Owner when admin is set, including a row that is also a moderator' do
      user = Fabricate(:user)

      user.update!(admin: true, moderator: true)

      expect(user.reload.role_id).to eq owner_role.id
      expect(user).to be_admin
      expect(user).to be_moderator
      expect(user.role).to eq 'admin'
      expect(user.role?('admin')).to be true
      expect(User.admins).to include(user)
      expect(User.moderators).to include(user)
      expect(User.staff).to include(user)
    end

    it 'stores Moderator, then clears role_id when both flags are removed' do
      user = Fabricate(:user)

      user.update!(moderator: true)
      expect(user.reload.role_id).to eq moderator_role.id
      expect(user.role).to eq 'moderator'
      expect(user.role?('admin')).to be false

      user.update!(admin: false, moderator: false)
      expect(user.reload.role_id).to be_nil
      expect(user.role).to eq 'user'
      expect(User.admins).not_to include(user)
      expect(User.staff).not_to include(user)
    end

    it 'syncs role=, promote!, and demote!' do
      user = Fabricate(:user)
      user.role = 'admin'
      user.save!

      expect(user.reload.role_id).to eq owner_role.id
      expect(user).to be_admin
      expect(user).not_to be_moderator

      user.demote!
      expect(user.reload.role_id).to eq moderator_role.id
      expect(user.role).to eq 'moderator'

      user.demote!
      expect(user.reload.role_id).to be_nil

      user.promote!
      expect(user.reload.role_id).to eq moderator_role.id
      user.promote!
      expect(user.reload.role_id).to eq owner_role.id
    end

    it 'does not rewrite role_id when an unrelated attribute changes' do
      user = Fabricate(:user, admin: true)
      custom = UserRole.create!(name: 'Helper', permissions_as_keys: %w(manage_reports))
      user.update_columns(role_id: custom.id)

      user.update!(locale: 'ja')

      expect(user.reload.role_id).to eq custom.id
      expect(user).to be_admin
      expect(user.role).to eq 'admin'
    end
  end

  describe '#user_role=' do
    it 'maps Owner, Moderator, and Everyone back onto the legacy flags' do
      user = Fabricate(:user)

      user.user_role = owner_role
      user.save!
      expect(user.reload.role_id).to eq owner_role.id
      expect(user).to be_admin
      expect(user).not_to be_moderator

      user.user_role = moderator_role
      user.save!
      expect(user.reload.role_id).to eq moderator_role.id
      expect(user).not_to be_admin
      expect(user).to be_moderator

      user.user_role = nil
      user.save!
      expect(user.reload.role_id).to be_nil
      expect(user.role).to eq 'user'
      expect(user.user_role).to eq UserRole.everyone
    end

    it 'refuses Admin and custom roles instead of promoting the legacy flags' do
      user = Fabricate(:user)
      custom = UserRole.create!(name: 'Helper', permissions_as_keys: %w(administrator))

      expect { user.user_role = admin_role }.to raise_error(ArgumentError)
      expect { user.user_role = custom }.to raise_error(ArgumentError)
      expect(user).not_to be_admin
      expect(user.role_id).to be_nil
    end
  end

  describe '#user_role and #can?' do
    it 'reads the assigned role, and Everyone when role_id is nil' do
      user = Fabricate(:user)
      expect(user.user_role).to eq UserRole.everyone
      expect(user.can?(:invite_users)).to be true
      expect(user.can?(:manage_reports)).to be false

      user.update!(admin: true)
      expect(user.user_role).to eq owner_role
      expect(user.can?(:manage_webhooks)).to be true
      expect(user.account.user_role).to eq owner_role
    end
  end

  describe 'UserRole#users inverse' do
    it 'links assigned_role back to the same role record' do
      user = Fabricate(:user, admin: true)
      loaded = UserRole.includes(:users).find(owner_role.id)
      linked = loaded.users.detect { |record| record.id == user.id }

      expect(linked).to be_present
      expect(linked.assigned_role).to equal(loaded)
    end
  end

  describe 'admin account serializer' do
    it 'keeps the legacy role string' do
      user = Fabricate(:user, moderator: true)
      expect(REST::Admin::AccountSerializer.new(user.account).role).to eq 'moderator'
    end
  end
end
