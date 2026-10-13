require 'rails_helper'

describe Api::V1::Accounts::CredentialsController do
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }

  def authorize_owner(resource_owner)
    access_token = Fabricate(:accessible_access_token, resource_owner_id: resource_owner.id, scopes: scopes)
    allow(controller).to receive(:doorkeeper_token) { access_token }
  end

  def discard_credentials_user(record)
    return unless record&.id

    account_id = record.account_id
    Setting.unscoped.where(thing_type: 'User', thing_id: record.id).delete_all
    UserPreferenceRevision.where(user_id: record.id).delete_all
    MediaAttachment.where(account_id: account_id).delete_all if account_id
    Account.where(id: account_id).delete_all
    User.where(id: record.id).delete_all
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
        authorize_owner(user_with_role('Moderator'))

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
        expect(admin_user.role).to eq admin_role
        expect(admin_user).not_to be_admin
        expect(admin_user).not_to be_moderator
      end

      it 'returns the Owner role when role_id is Owner' do
        authorize_owner(user_with_role('Owner'))

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

    describe 'GET #show with the profile scope' do
      let(:scopes) { 'profile' }

      it 'returns the credential account' do
        get :show

        expect(response).to have_http_status(200)
        expect(body_as_json[:id]).to eq user.account.id.to_s
        expect(body_as_json[:username]).to eq 'alice'
        expect(body_as_json).to have_key(:source)
      end
    end

    describe 'GET #show with the read scope' do
      let(:scopes) { 'read' }

      it 'returns http success' do
        get :show
        expect(response).to have_http_status(200)
      end
    end

    describe 'GET #show with write:accounts only' do
      let(:scopes) { 'write:accounts' }

      it 'returns http forbidden' do
        get :show
        expect(response).to have_http_status(403)
      end
    end

    describe 'PATCH #update' do
      let(:scopes) { 'write:accounts' }

      describe 'with valid data' do
        self.use_transactional_tests = false

        after { discard_credentials_user(user) }

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

    describe 'GET #show source preferences' do
      let(:scopes) { 'read:accounts' }
      let(:user) { Fabricate(:user, locale: 'ja', account: Fabricate(:account, username: 'alice', locked: true)) }

      def authorize_application(app_name)
        application = Fabricate(:application, name: app_name)
        access_token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes, application: application)
        allow(controller).to receive(:doorkeeper_token) { access_token }
      end

      it 'keeps a locked account private for a normal client when privacy is unset' do
        get :show

        expect(response).to have_http_status(200)
        expect(body_as_json[:locked]).to be true
        expect(body_as_json[:source][:privacy]).to eq 'private'
        expect(body_as_json[:source][:sensitive]).to be false
        expect(body_as_json[:source][:language]).to be_nil
        expect(user.preferred_posting_language).to eq 'ja'
      end

      it 'uses public for an unlocked account when privacy is unset' do
        user.account.update!(locked: false)

        get :show

        expect(body_as_json[:locked]).to be false
        expect(body_as_json[:source][:privacy]).to eq 'public'
        expect(body_as_json[:source][:language]).to be_nil
      end

      it 'masks locked for official iOS when unlocked_for_official_app is set and privacy is unset' do
        user.settings['unlocked_for_official_app'] = true
        authorize_application('Mastodon for iOS')

        get :show

        expect(response).to have_http_status(200)
        expect(body_as_json[:locked]).to be false
        expect(body_as_json[:source][:privacy]).to eq 'public'
        expect(user.account.reload).to be_locked
      end

      it 'masks locked for official Android when unlocked_for_official_app is set and privacy is unset' do
        user.settings['unlocked_for_official_app'] = true
        authorize_application('Mastodon for Android')

        get :show

        expect(body_as_json[:locked]).to be false
        expect(body_as_json[:source][:privacy]).to eq 'public'
        expect(user.account.reload).to be_locked
      end

      it 'keeps a stored privacy value when the official app mask clears locked' do
        user.settings['unlocked_for_official_app'] = true
        user.settings['default_privacy'] = 'direct'
        authorize_application('Mastodon for iOS')

        get :show

        expect(body_as_json[:locked]).to be false
        expect(body_as_json[:source][:privacy]).to eq 'direct'
        expect(user.account.reload).to be_locked
      end

      it 'does not mask locked for a normal client when unlocked_for_official_app is set' do
        user.settings['unlocked_for_official_app'] = true

        get :show

        expect(body_as_json[:locked]).to be true
        expect(body_as_json[:source][:privacy]).to eq 'private'
      end

      it 'does not accept read:preferences alone' do
        allow(controller).to receive(:doorkeeper_token) do
          Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:preferences')
        end

        get :show

        expect(response).to have_http_status(403)
      end
    end

    describe 'PATCH #update with the profile scope' do
      let(:scopes) { 'profile' }

      it 'returns http forbidden' do
        patch :update, params: { display_name: 'Nope' }

        expect(response).to have_http_status(403)
        expect(user.account.reload.display_name).not_to eq 'Nope'
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
      self.use_transactional_tests = false

      let(:scopes) { 'write:accounts' }

      before { allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async) }
      after { discard_credentials_user(user) }

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

      it 'writes the current privacy and sensitive getters when source omits them' do
        user.account.update!(locked: true)

        patch :update, params: { source: { language: 'de' } }, as: :json

        expect(response).to have_http_status(200)
        privacy = Setting.unscoped.find_by!(thing_type: 'User', thing_id: user.id, var: 'default_privacy')
        sensitive = Setting.unscoped.find_by!(thing_type: 'User', thing_id: user.id, var: 'default_sensitive')
        expect(privacy.value).to eq 'private'
        expect(sensitive.value).to be false
        expect(user.setting_default_language).to eq 'de'
      end

      it 'does not replace a stored privacy when source privacy is null' do
        user.settings['default_privacy'] = 'direct'

        patch :update, params: { source: { privacy: nil, language: 'de' } }, as: :json

        expect(response).to have_http_status(200)
        expect(user.setting_default_privacy).to eq 'direct'
        expect(user.setting_default_language).to eq 'de'
      end

      it 'returns stored source preferences without deriving the posting language' do
        user.update!(locale: 'ja')

        patch :update, params: {
          note: 'Kept',
          source: {
            privacy: 'direct',
            sensitive: false,
            language: 'ja-JP',
          },
        }, as: :json

        source = body_as_json[:source]
        expect(response).to have_http_status(200)
        expect(source[:privacy]).to eq 'direct'
        expect(source[:privacy]).to eq user.setting_default_privacy
        expect(source[:sensitive]).to be false
        expect(source[:sensitive]).to eq user.setting_default_sensitive
        expect(source[:language]).to eq 'ja-JP'
        expect(source[:language]).to eq user.setting_default_language
        expect(user.preferred_posting_language).to eq 'ja'
        expect(source[:note]).to eq 'Kept'
        expect(source).to include(:fields, :follow_requests_count, :hide_collections, :discoverable, :indexable)
      end
    end

    describe 'PATCH #update with the write scope' do
      let(:scopes) { 'write' }

      before { allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async) }

      it 'returns http success' do
        patch :update, params: { display_name: 'Writer' }

        expect(response).to have_http_status(200)
        expect(user.account.reload.display_name).to eq 'Writer'
      end
    end

    describe 'PATCH #update with read:preferences only' do
      let(:scopes) { 'read:preferences' }

      it 'returns http forbidden' do
        patch :update, params: { display_name: 'Nope' }

        expect(response).to have_http_status(403)
        expect(user.account.reload.display_name).not_to eq 'Nope'
      end
    end

    describe 'PATCH #update from an official app' do
      let(:scopes) { 'write:accounts' }
      let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice', locked: true)) }

      before { allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async) }

      it 'does not apply the show locked mask' do
        user.settings['unlocked_for_official_app'] = true
        application = Fabricate(:application, name: 'Mastodon for iOS')
        access_token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes, application: application)
        allow(controller).to receive(:doorkeeper_token) { access_token }

        patch :update, params: { display_name: 'Still locked' }

        expect(response).to have_http_status(200)
        expect(body_as_json[:locked]).to be true
        expect(body_as_json[:source][:privacy]).to eq 'private'
        expect(user.account.reload).to be_locked
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
