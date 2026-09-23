# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db', 'post_migrate', '20260923020002_backfill_user_role_ids.rb')

RSpec.describe BackfillUserRoleIds, type: :model do # rubocop:disable Metrics/BlockLength
  def seed_roles
    load Rails.root.join('db', 'seeds', '03_roles.rb')
  end

  describe 'default role seed' do
    it 'creates Everyone, Moderator, Admin, and Owner once' do
      described_class::User.update_all(role_id: nil)
      UserRole.delete_all

      seed_roles
      seed_roles

      everyone = UserRole.find(-99)
      expect(everyone.permissions).to eq UserRole::FLAGS[:invite_users]
      expect(UserRole.where(id: -99).count).to eq 1
      expect(UserRole.where(name: 'Moderator').count).to eq 1
      expect(UserRole.where(name: 'Admin').count).to eq 1
      expect(UserRole.where(name: 'Owner').count).to eq 1
      expect(UserRole.count).to eq 4

      expect(UserRole.find_by!(name: 'Moderator').position).to eq 10
      expect(UserRole.find_by!(name: 'Admin').position).to eq 100
      expect(UserRole.find_by!(name: 'Owner').position).to eq 1000
      expect(UserRole.find_by!(name: 'Owner').permissions_as_keys).to eq %w(administrator)
    end
  end

  describe '#up' do
    it 'backfills owner for admins, including rows that are also moderators' do
      seed_roles
      owner_role     = UserRole.find_by!(name: 'Owner')
      moderator_role = UserRole.find_by!(name: 'Moderator')

      regular   = Fabricate(:user, admin: false, moderator: false)
      moderator = Fabricate(:user, admin: false, moderator: true)
      admin     = Fabricate(:user, admin: true, moderator: false)
      both      = Fabricate(:user, admin: true, moderator: true)
      described_class::User.where(id: [regular, moderator, admin, both].map(&:id)).update_all(role_id: nil)

      described_class.new.up

      expect(regular.reload.role_id).to be_nil
      expect(moderator.reload.role_id).to eq moderator_role.id
      expect(admin.reload.role_id).to eq owner_role.id
      expect(both.reload.role_id).to eq owner_role.id
    end

    it 'leaves legacy boolean role checks on the admin and moderator columns' do
      seed_roles
      both = Fabricate(:user, admin: true, moderator: true)
      moderator = Fabricate(:user, admin: false, moderator: true)

      described_class.new.up

      both.reload
      moderator.reload

      expect(both).to be_admin
      expect(both).to be_moderator
      expect(both.role).to eq UserRole.find_by!(name: 'Owner')

      expect(moderator).not_to be_admin
      expect(moderator).to be_moderator
      expect(moderator.role).to eq UserRole.find_by!(name: 'Moderator')

      expect(User.where(admin: true)).to include(both)
      expect(User.where(admin: true)).not_to include(moderator)
      expect(User.where(moderator: true)).to include(both, moderator)
    end
  end
end
