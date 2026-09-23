require 'rails_helper'

describe Admin::RolesController do
  render_views

  let(:admin) { Fabricate(:user, admin: true) }

  before do
    sign_in admin, scope: :user
  end

  describe 'POST #promote' do
    subject { post :promote, params: { account_id: user.account_id } }

    let(:user) { Fabricate(:user, moderator: false, admin: false) }

    it 'promotes user' do
      expect(subject).to redirect_to admin_account_path(user.account_id)
      expect(user.reload).to be_moderator
    end
  end

  describe 'POST #promote when the resulting role would outrank the actor' do
    it 'leaves role_id and the legacy booleans unchanged' do
      actor = Fabricate(:user, admin: false, moderator: false)
      actor.update_columns(role_id: UserRole.find_by!(name: 'Admin').id)
      target = Fabricate(:user, admin: false, moderator: true)
      sign_in actor, scope: :user

      expect do
        post :promote, params: { account_id: target.account_id }, format: :json
      end.not_to(change { target.reload.attributes.slice('role_id', 'admin', 'moderator') })

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST #demote' do
    subject { post :demote, params: { account_id: user.account_id } }

    let(:user) { Fabricate(:user, moderator: true, admin: false) }

    it 'demotes user' do
      expect(subject).to redirect_to admin_account_path(user.account_id)
      expect(user.reload).not_to be_moderator
    end
  end
end
