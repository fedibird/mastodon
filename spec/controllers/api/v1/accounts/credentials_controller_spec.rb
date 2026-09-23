require 'rails_helper'

describe Api::V1::Accounts::CredentialsController do
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }

  def authorize_owner(resource_owner)
    access_token = Fabricate(:accessible_access_token, resource_owner_id: resource_owner.id, scopes: scopes)
    allow(controller).to receive(:doorkeeper_token) { access_token }
  end

  context 'with an oauth token' do
    before do
      allow(controller).to receive(:doorkeeper_token) { token }
    end

    describe 'GET #show' do # rubocop:disable Metrics/BlockLength
      let(:scopes) { 'read:accounts' }

      it 'returns http success' do
        get :show
        expect(response).to have_http_status(200)
      end

      it 'includes source visibility fields' do
        user.account.update!(hide_collections: true, discoverable: false, indexable: false)
        get :show
        source = body_as_json[:source]

        expect(source[:hide_collections]).to be true
        expect(source[:discoverable]).to be false
        expect(source[:indexable]).to be false
      end

      it 'returns the Everyone role and keeps the source contract' do
        get :show
        role = body_as_json[:role]
        source = body_as_json[:source]

        expect(role[:id]).to eq '-99'
        expect(role[:name]).to eq ''
        expect(role[:id]).to be_a(String)
        expect(role[:permissions]).to be_a(String)
        expect(source).to include(:privacy, :sensitive, :language, :note, :fields, :hide_collections, :discoverable, :indexable)
      end

      it 'returns the Moderator role' do
        authorize_owner(Fabricate(:user, moderator: true))

        get :show

        expect(body_as_json[:role][:name]).to eq 'Moderator'
        expect(body_as_json[:role][:id]).to eq UserRole.find_by!(name: 'Moderator').id.to_s
      end

      it 'returns the Admin role when role_id is Admin and the legacy flags are off' do
        admin_role = UserRole.find_by!(name: 'Admin')
        admin_user = Fabricate(:user, admin: false, moderator: false)
        admin_user.update_columns(role_id: admin_role.id)
        authorize_owner(admin_user)

        get :show

        expect(body_as_json[:role][:name]).to eq 'Admin'
        expect(body_as_json[:role][:id]).to eq admin_role.id.to_s
        expect(admin_user.role).to eq 'user'
      end

      it 'returns the Owner role for a legacy admin' do
        authorize_owner(Fabricate(:user, admin: true))

        get :show

        expect(body_as_json[:role][:name]).to eq 'Owner'
        expect(body_as_json[:role][:permissions]).to eq UserRole::Flags::ALL.to_s
      end

      it 'returns a custom role with computed permissions' do
        UserRole.everyone.update!(permissions: UserRole::FLAGS[:invite_users])
        custom = UserRole.create!(
          name: 'Helper',
          position: 5,
          permissions_as_keys: %w(manage_reports),
          color: '#112233',
          highlighted: true
        )
        custom_user = Fabricate(:user, admin: false, moderator: false)
        custom_user.update_columns(role_id: custom.id)
        authorize_owner(custom_user)

        get :show

        role = body_as_json[:role]
        combined = UserRole::FLAGS[:invite_users] | UserRole::FLAGS[:manage_reports]
        expect(role[:id]).to eq custom.id.to_s
        expect(role[:name]).to eq 'Helper'
        expect(role[:permissions]).to eq combined.to_s
        expect(role[:color]).to eq '#112233'
        expect(role[:highlighted]).to be true
        expect(role[:id]).to be_a(String)
        expect(role[:permissions]).to be_a(String)
        expect(body_as_json[:source]).to include(:privacy, :hide_collections, :discoverable, :indexable)
      end
    end

    describe 'PATCH #update' do
      let(:scopes) { 'write:accounts' }

      describe 'with valid data' do
        before do
          allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async)

          patch :update, params: {
            display_name: "Alice Isn't Dead",
            note: "Hi!\n\nToot toot!",
            avatar: fixture_file_upload('avatar.gif', 'image/gif'),
            header: fixture_file_upload('attachment.jpg', 'image/jpeg'),
            source: {
              privacy: 'unlisted',
              sensitive: true,
            }
          }
        end

        it 'returns http success' do
          expect(response).to have_http_status(200)
        end

        it 'updates account info' do
          user.account.reload

          expect(user.account.display_name).to eq("Alice Isn't Dead")
          expect(user.account.note).to eq("Hi!\n\nToot toot!")
          expect(user.account.avatar).to exist
          expect(user.account.header).to exist
          expect(user.setting_default_privacy).to eq('unlisted')
          expect(user.setting_default_sensitive).to eq(true)
        end

        it 'queues up an account update distribution' do
          expect(ActivityPub::UpdateDistributionWorker).to have_received(:perform_async).with(user.account_id)
        end
      end

      describe 'with empty source list' do
        before do
          patch :update, params: {
            display_name: "I'm a cat",
            source: {},
          }, as: :json
        end

        it 'returns http success' do
          expect(response).to have_http_status(200)
        end
     end

      describe 'with invalid data' do
        before do
          patch :update, params: { note: 'This is too long. ' * 30 }
        end

        it 'returns http unprocessable entity' do
          expect(response).to have_http_status(:unprocessable_entity)
        end
      end
    end

    describe 'PATCH #update hide_collections' do
      let(:scopes) { 'write:accounts' }

      before { allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async) }

      it 'sets hide_collections to true' do
        patch :update, params: { hide_collections: true }

        expect(response).to have_http_status(200)
        expect(user.account.reload.hide_collections).to be true
      end

      it 'sets hide_collections to false' do
        user.account.update!(hide_collections: true)

        patch :update, params: { hide_collections: false }, as: :json

        expect(response).to have_http_status(200)
        expect(user.account.reload.hide_collections).to be false
      end

      it 'does not change hide_collections when omitted' do
        user.account.update!(hide_collections: true)

        patch :update, params: { display_name: 'Alice' }

        expect(user.account.reload.hide_collections).to be true
      end
    end

    describe 'PATCH #update source visibility fields' do
      let(:scopes) { 'write:accounts' }

      before { allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async) }

      it 'returns updated source visibility fields' do
        user.account.update!(hide_collections: true, discoverable: false, indexable: false)

        patch :update, params: {
          hide_collections: false,
          discoverable: true,
          indexable: true,
        }, as: :json

        source = body_as_json[:source]
        expect(source[:hide_collections]).to be false
        expect(source[:discoverable]).to be true
        expect(source[:indexable]).to be true
      end
    end
  end

  context 'without an oauth token' do
    before do
      allow(controller).to receive(:doorkeeper_token) { nil }
    end

    describe 'GET #show' do
      it 'returns http unauthorized' do
        get :show
        expect(response).to have_http_status(:unauthorized)
      end
    end

    describe 'PATCH #update' do
      it 'returns http unauthorized' do
        patch :update, params: { note: 'Foo' }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
