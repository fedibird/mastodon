# frozen_string_literal: true

require 'rails_helper'

# Examples cover the assignment matrix in one controller flow.
# rubocop:disable Metrics/BlockLength
describe Admin::Users::RolesController do
  def user_with_role(role)
    user = Fabricate(:user, admin: false, moderator: false)
    user.update_columns(role_id: role.id)
    user
  end

  let(:admin_role) { UserRole.find_by!(name: 'Admin') }
  let(:owner_role) { UserRole.find_by!(name: 'Owner') }
  let(:moderator_role) { UserRole.find_by!(name: 'Moderator') }
  let(:owner) { Fabricate(:user, admin: true) }

  describe 'PATCH #update' do
    it 'lets a manage_roles actor assign a lower custom role' do
      sign_in owner, scope: :user
      custom = UserRole.create!(name: 'Assigned custom', position: 8, permissions_as_keys: %w(invite_users))
      target = Fabricate(:user, admin: false, moderator: false)

      patch :update, params: { user_id: target.id, user: { role_id: custom.id } }

      expect(response).to redirect_to(admin_account_path(target.account_id))
      target.reload
      expect(target.role_id).to eq custom.id
      expect(target.admin).to be false
      expect(target.moderator).to be false
      expect(Admin::ActionLog.where(action: 'change_role', target: target).exists?).to be true
    end

    it 'lets the Admin role assign Moderator and Admin, and refuses Owner' do
      actor = user_with_role(admin_role)
      sign_in actor, scope: :user

      moderator_target = Fabricate(:user, admin: false, moderator: false)
      patch :update, params: { user_id: moderator_target.id, user: { role_id: moderator_role.id } }
      moderator_target.reload
      expect(moderator_target.role_id).to eq moderator_role.id
      expect(moderator_target.moderator).to be true
      expect(moderator_target.admin).to be false

      admin_target = Fabricate(:user, admin: false, moderator: false)
      patch :update, params: { user_id: admin_target.id, user: { role_id: admin_role.id } }
      admin_target.reload
      expect(admin_target.role_id).to eq admin_role.id
      expect(admin_target.admin).to be false
      expect(admin_target.moderator).to be false

      owner_target = Fabricate(:user, admin: false, moderator: false)
      patch :update, params: { user_id: owner_target.id, user: { role_id: owner_role.id } }
      expect(response).to have_http_status(:ok)
      owner_target.reload
      expect(owner_target.role_id).to be_nil
      expect(owner_target.admin).to be false
      expect(owner_target.moderator).to be false
    end

    it 'lets a position 50 role assign lower and equal roles, and refuses a higher role' do
      limited = UserRole.create!(name: 'Controller 50', position: 50, permissions_as_keys: %w(manage_roles))
      sign_in user_with_role(limited), scope: :user
      lower = UserRole.create!(name: 'Controller lower', position: 20, permissions_as_keys: %w(invite_users))
      equal = UserRole.create!(name: 'Controller equal', position: 50, permissions_as_keys: %w(invite_users))
      higher = UserRole.create!(name: 'Controller higher', position: 51, permissions_as_keys: %w(invite_users))

      lower_target = Fabricate(:user, admin: false, moderator: false)
      patch :update, params: { user_id: lower_target.id, user: { role_id: lower.id } }
      expect(lower_target.reload.role_id).to eq lower.id

      equal_target = Fabricate(:user, admin: false, moderator: false)
      patch :update, params: { user_id: equal_target.id, user: { role_id: equal.id } }
      expect(equal_target.reload.role_id).to eq equal.id

      higher_target = Fabricate(:user, admin: false, moderator: false)
      patch :update, params: { user_id: higher_target.id, user: { role_id: higher.id } }
      expect(response).to have_http_status(:ok)
      expect(higher_target.reload.role_id).to be_nil
    end

    it 'refuses to change a peer or higher target' do
      actor = user_with_role(admin_role)
      sign_in actor, scope: :user
      peer = user_with_role(admin_role)
      higher = Fabricate(:user, admin: true)
      custom = UserRole.create!(name: 'Not assigned', position: 3, permissions_as_keys: %w(invite_users))

      patch :update, params: { user_id: peer.id, user: { role_id: custom.id } }, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(peer.reload.role_id).to eq admin_role.id

      patch :update, params: { user_id: higher.id, user: { role_id: custom.id } }, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(higher.reload.role_id).to eq owner_role.id
    end

    it 'assigns Everyone by clearing role_id' do
      sign_in owner, scope: :user
      custom = UserRole.create!(name: 'Clear me', position: 6, permissions_as_keys: %w(invite_users))
      target = Fabricate(:user, admin: false, moderator: false)
      target.update_columns(role_id: custom.id)

      patch :update, params: { user_id: target.id, user: { role_id: '' } }

      target.reload
      expect(target.role_id).to be_nil
      expect(target.admin).to be false
      expect(target.moderator).to be false
    end
  end
end
# rubocop:enable Metrics/BlockLength
