# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User, type: :model do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:owner_role) { UserRole.find_by!(name: 'Owner') }
  let(:moderator_role) { UserRole.find_by!(name: 'Moderator') }
  let(:admin_role) { UserRole.find_by!(name: 'Admin') }

  describe '#role' do
    it 'returns Everyone when role_id is nil and ignores legacy booleans' do
      user = Fabricate(:user, admin: true, moderator: false)

      expect(user.role_id).to be_nil
      expect(user.role).to eq UserRole.everyone
      expect(user.role).to be_a(UserRole)
      expect(user.role).not_to be_a(String)
      expect(user).to be_admin
      expect(user).not_to be_moderator
      expect(user.can?(:manage_reports)).to be false

      user.update!(admin: true, moderator: true)

      expect(user.reload.role_id).to be_nil
      expect(user.role).to eq UserRole.everyone
      expect(user).to be_admin
      expect(user).to be_moderator
      expect(user.can?(:manage_reports)).to be false

      moderator_flag = Fabricate(:user, admin: false, moderator: true)
      expect(moderator_flag.role_id).to be_nil
      expect(moderator_flag.role).to eq UserRole.everyone
      expect(moderator_flag.can?(:manage_reports)).to be false
    end

    it 'returns the role_id record for a custom role' do
      custom = UserRole.create!(name: 'Helper', position: 4, permissions_as_keys: %w(manage_reports))
      user = Fabricate(:user, admin: true, moderator: true)
      user.update!(role_id: custom.id)

      expect(user.reload.role).to eq custom
      expect(user).to be_admin
      expect(user.can?(:manage_reports)).to be true
      expect(user.account.role).to eq custom
    end
  end

  describe 'UserRole#users inverse' do
    it 'links role back to the same role record' do
      user = user_with_role('Owner')
      loaded = UserRole.includes(:users).find(owner_role.id)
      linked = loaded.users.detect { |record| record.id == user.id }

      expect(linked).to be_present
      expect(linked.role).to equal(loaded)
    end
  end

  describe 'admin account serializer' do
    it 'returns the Moderator role entity' do
      user = user_with_role('Moderator')
      expect(REST::Admin::AccountSerializer.new(user.account).role).to eq moderator_role
    end

    it 'returns Everyone for an ordinary local user' do
      user = Fabricate(:user, admin: false, moderator: false)
      expect(REST::Admin::AccountSerializer.new(user.account).role).to eq UserRole.everyone
    end
  end
end
