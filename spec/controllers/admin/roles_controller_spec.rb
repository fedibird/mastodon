# frozen_string_literal: true

require 'rails_helper'

# Examples cover role CRUD access, elevation, rename, and destroy together.
# rubocop:disable Metrics/BlockLength
describe Admin::RolesController do
  def user_with_role(role)
    user = Fabricate(:user, admin: false, moderator: false)
    user.update_columns(role_id: role.id)
    user
  end

  def sign_in_role(role)
    user = user_with_role(role)
    sign_in user, scope: :user
    user
  end

  let(:owner) { Fabricate(:user, admin: true) }
  let(:admin_role) { UserRole.find_by!(name: 'Admin') }

  describe 'access' do
    it 'allows index and create for a manage_roles role' do
      sign_in_role(admin_role)

      get :index
      expect(response).to have_http_status(:ok)

      expect do
        post :create, params: { user_role: { name: 'Created role', position: 10, permissions_as_keys: %w(manage_reports) } }
      end.to change(UserRole, :count).by(1)

      expect(response).to redirect_to(admin_roles_path)
    end

    it 'forbids index and create without manage_roles' do
      sign_in_role(UserRole.find_by!(name: 'Moderator'))

      get :index, format: :json
      expect(response).to have_http_status(:forbidden)

      expect do
        post :create, params: { user_role: { name: 'Denied role', position: 1 } }, format: :json
      end.not_to change(UserRole, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST #create' do
    before { sign_in_role(admin_role) }

    it 'allows permissions the actor has, including an equal position' do
      post :create, params: { user_role: { name: 'Equal role', position: admin_role.position, permissions_as_keys: %w(manage_roles manage_users) } }

      role = UserRole.find_by!(name: 'Equal role')
      expect(role.position).to eq admin_role.position
      expect(role.permissions_as_keys).to include('manage_roles', 'manage_users')
    end

    it 'refuses a permission the actor does not have' do
      expect do
        post :create, params: { user_role: { name: 'Devops role', position: 10, permissions_as_keys: %w(view_devops) } }
      end.not_to change(UserRole, :count)
    end

    it 'refuses a position above the actor' do
      expect do
        post :create, params: { user_role: { name: 'High role', position: admin_role.position + 1, permissions_as_keys: %w(manage_reports) } }
      end.not_to change(UserRole, :count)
    end

    it 'allows a new role to reuse a default role name' do
      %w(Owner Admin Moderator).each do |name|
        expect do
          post :create, params: { user_role: { name: name, position: 1, permissions_as_keys: %w(invite_users) } }
        end.to change(UserRole, :count).by(1)
      end
    end
  end

  describe 'PATCH #update' do
    before { sign_in_role(admin_role) }

    it 'updates a lower role' do
      role = UserRole.create!(name: 'Editable', position: 5, permissions_as_keys: %w(invite_users))

      patch :update, params: { id: role.id, user_role: { name: 'Edited', position: 6, color: '#112233', highlighted: '1', permissions_as_keys: %w(manage_reports) } }

      expect(response).to redirect_to(admin_roles_path)
      expect(role.reload.name).to eq 'Edited'
      expect(role.position).to eq 6
      expect(role.permissions_as_keys).to include('manage_reports')
    end

    it 'refuses a peer or higher role' do
      peer = UserRole.create!(name: 'Peer role', position: admin_role.position, permissions_as_keys: %w(invite_users))
      higher = UserRole.find_by!(name: 'Owner')

      patch :update, params: { id: peer.id, user_role: { name: 'Taken peer' } }, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(peer.reload.name).to eq 'Peer role'

      patch :update, params: { id: higher.id, user_role: { color: '#000000' } }, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(higher.reload.color).not_to eq '#000000'
    end

    it 'allows own color and highlighted, and keeps own permissions and position' do
      sign_in owner, scope: :user
      role = owner.role
      highlighted = role.highlighted

      patch :update, params: { id: role.id, user_role: { color: '#abcdef', highlighted: highlighted ? '0' : '1' } }
      expect(response).to redirect_to(admin_roles_path)
      expect(role.reload.color).to eq '#abcdef'
      expect(role.highlighted).to eq !highlighted

      patch :update, params: { id: role.id, user_role: { permissions_as_keys: %w(manage_reports), position: 10 } }
      expect(role.reload.position).to eq 1000
      expect(role.can?(:administrator)).to be true
    end

    it 'allows renaming Owner, Admin, and Moderator' do
      sign_in owner, scope: :user

      %w(Owner Admin Moderator).each do |name|
        role = UserRole.find_by!(name: name)
        patch :update, params: { id: role.id, user_role: { name: "#{name} renamed", position: role.position } }
        expect(role.reload.name).to eq "#{name} renamed"
      end
    end

    it 'lets an owner change highlighted and invite_users on Admin and Moderator' do
      sign_in owner, scope: :user
      moderator = UserRole.find_by!(name: 'Moderator')
      admin = UserRole.find_by!(name: 'Admin')

      patch :update, params: {
        id: moderator.id,
        user_role: { highlighted: '0', permissions_as_keys: moderator.permissions_as_keys + ['invite_users'] },
      }
      moderator.reload
      expect(moderator.highlighted).to be false
      expect(moderator.permissions_as_keys).to include('invite_users')

      patch :update, params: {
        id: admin.id,
        user_role: { highlighted: '1', permissions_as_keys: admin.permissions_as_keys + ['invite_users'] },
      }
      admin.reload
      expect(admin.highlighted).to be true
      expect(admin.permissions_as_keys).to include('invite_users')
    end
  end

  describe 'DELETE #destroy' do
    it 'deletes a lower custom role' do
      sign_in owner, scope: :user
      role = UserRole.create!(name: 'Disposable', position: 4, permissions_as_keys: %w(invite_users))

      expect do
        delete :destroy, params: { id: role.id }
      end.to change(UserRole, :count).by(-1)

      expect(response).to redirect_to(admin_roles_path)
      expect(Admin::ActionLog.where(action: 'destroy', target_type: 'UserRole').exists?).to be true
    end

    it 'deletes a lower default role' do
      sign_in owner, scope: :user
      moderator = UserRole.find_by!(name: 'Moderator')

      expect do
        delete :destroy, params: { id: moderator.id }
      end.to change(UserRole, :count).by(-1)

      expect(response).to redirect_to(admin_roles_path)
    end

    it 'refuses Everyone, the actor role, and a peer or higher role' do
      sign_in owner, scope: :user
      peer = UserRole.create!(name: 'Owner peer', position: 1000, permissions_as_keys: %w(invite_users))

      [UserRole.everyone, UserRole.find_by!(name: 'Owner'), peer].each do |role|
        expect do
          delete :destroy, params: { id: role.id }, format: :json
        end.not_to change(UserRole, :count)

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
