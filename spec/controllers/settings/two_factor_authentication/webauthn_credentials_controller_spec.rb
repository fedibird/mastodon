# frozen_string_literal: true

require 'rails_helper'
require 'webauthn/fake_client'

describe Settings::TwoFactorAuthentication::WebauthnCredentialsController do
  render_views

  let(:user) { Fabricate(:user) }
  let(:domain) { "#{Rails.configuration.x.use_https ? 'https' : 'http' }://#{Rails.configuration.x.web_domain}" }
  let(:fake_client) { WebAuthn::FakeClient.new(domain) }

  def add_webauthn_credential(user)
    Fabricate(:webauthn_credential, user_id: user.id, nickname: 'USB Key')
  end

  describe 'GET #new' do
    context 'when signed in' do
      before do
        sign_in user, scope: :user
      end

      context 'when user has otp enabled' do
        before do
          user.update(otp_required_for_login: true)
        end

        it 'returns http success' do
          get :new

          expect(response).to have_http_status(200)
        end
      end

      context 'when user does not have otp enabled' do
        before do
          user.update(otp_required_for_login: false)
        end

        it 'requires otp enabled first' do
          get :new

          expect(response).to redirect_to settings_two_factor_authentication_methods_path
          expect(flash[:error]).to be_present
        end
      end
    end
  end

  describe 'GET #index' do
    context 'when signed in' do
      before do
        sign_in user, scope: :user
      end

      context 'when user has otp enabled' do
        before do
          user.update(otp_required_for_login: true)
        end

        context 'when user has webauthn enabled' do
          before do
            user.update(webauthn_id: WebAuthn.generate_user_id)
            add_webauthn_credential(user)
          end

          it 'returns http success' do
            get :index

            expect(response).to have_http_status(200)
          end
        end

        context 'when user does not has webauthn enabled' do
          it 'redirects to 2FA methods list page' do
            get :index

            expect(response).to redirect_to settings_two_factor_authentication_methods_path
            expect(flash[:error]).to be_present
          end
        end
      end

      context 'when user does not have otp enabled' do
        before do
          user.update(otp_required_for_login: false)
        end

        it 'requires otp enabled first' do
          get :index

          expect(response).to redirect_to settings_two_factor_authentication_methods_path
          expect(flash[:error]).to be_present
        end
      end
    end

    context 'when not signed in' do
      it 'redirects to login' do
        delete :index

        expect(response).to redirect_to new_user_session_path
      end
    end
  end

  describe 'GET /options #options' do
    context 'when signed in' do
      before do
        sign_in user, scope: :user
      end

      context 'when user has otp enabled' do
        before do
          user.update(otp_required_for_login: true)
        end

        context 'when user has webauthn enabled' do
          before do
            user.update(webauthn_id: WebAuthn.generate_user_id)
            add_webauthn_credential(user)
          end

          it 'returns http success' do
            get :options

            expect(response).to have_http_status(200)
          end

          it 'stores the challenge on the session' do
            get :options

            expect(@controller.session[:webauthn_challenge]).to be_present
          end

          it 'does not change webauthn_id' do
            expect { get :options }.to_not change { user.webauthn_id }
          end

          it "includes existing credentials in list of excluded credentials" do
            get :options

            excluded_credentials_ids = JSON.parse(response.body)['excludeCredentials'].map { |credential| credential['id'] }
            expect(excluded_credentials_ids).to match_array(user.webauthn_credentials.pluck(:external_id))
          end

          it 'keeps the existing timeout, RP name, and user id' do
            get :options

            body = JSON.parse(response.body)
            expect(body['timeout']).to eq(120_000)
            expect(body['rp']).to eq('name' => 'Mastodon')
            expect(body.dig('user', 'id')).to eq(user.webauthn_id)
            expect(body['pubKeyCredParams'].map { |param| param['alg'] }).to include(-7)
          end
        end

        context 'when user does not have webauthn enabled' do
          it 'returns http success' do
            get :options

            expect(response).to have_http_status(200)
          end

          it 'stores the challenge on the session' do
            get :options

            expect(@controller.session[:webauthn_challenge]).to be_present
          end

          it 'sets user webauthn_id' do
            get :options

            expect(user.reload.webauthn_id).to be_present
          end
        end
      end

      context 'when user has not enabled otp' do
        before do
          user.update(otp_required_for_login: false)
        end

        it 'requires otp enabled first' do
          get :options

          expect(response).to redirect_to settings_two_factor_authentication_methods_path
          expect(flash[:error]).to be_present
        end
      end
    end

    context 'when not signed in' do
      it 'redirects to login' do
        get :options

        expect(response).to redirect_to new_user_session_path
      end
    end
  end

  describe 'POST #create' do
    let(:nickname) { 'SecurityKeyNickname' }

    let(:challenge) do
      WebAuthn::Credential.options_for_create(
        user: { id: user.id, name: user.account.username, display_name: user.account.display_name }
      ).challenge
    end

    let(:new_webauthn_credential) { fake_client.create(challenge: challenge) }

    context 'when signed in' do
      before do
        sign_in user, scope: :user
      end

      context 'when user has enabled otp' do
        before do
          user.update(otp_required_for_login: true)
        end

        context 'when user has enabled webauthn' do
          before do
            user.update(webauthn_id: WebAuthn.generate_user_id)
            add_webauthn_credential(user)
          end

          context 'when creation succeeds' do
            it 'returns http success' do
              @controller.session[:webauthn_challenge] = challenge

              post :create, params: { credential: new_webauthn_credential, nickname: nickname }

              expect(response).to have_http_status(200)
            end

            it 'adds a new credential to user credentials' do
              @controller.session[:webauthn_challenge] = challenge

              expect do
                post :create, params: { credential: new_webauthn_credential, nickname: nickname }
              end.to change { user.webauthn_credentials.count }.by(1)
            end

            it 'does not change webauthn_id' do
              @controller.session[:webauthn_challenge] = challenge

              expect do
                post :create, params: { credential: new_webauthn_credential, nickname: nickname }
              end.to_not change { user.webauthn_id }
            end
          end

          context 'when the nickname is already used' do
            it 'fails' do
              @controller.session[:webauthn_challenge] = challenge

              post :create, params: { credential: new_webauthn_credential, nickname: 'USB Key' }

              expect(response).to have_http_status(422)
              expect(flash[:error]).to be_present
            end
          end

          context 'when the credential already exists' do
            before do
              user2 = Fabricate(:user)
              public_key_credential = WebAuthn::Credential.from_create(new_webauthn_credential)
              Fabricate(:webauthn_credential,
                        user_id: user2.id,
                        external_id: public_key_credential.id,
                        public_key: public_key_credential.public_key)
            end

            it 'fails' do
              @controller.session[:webauthn_challenge] = challenge

              expect do
                post :create, params: { credential: new_webauthn_credential, nickname: nickname }
              end.to_not change { user.webauthn_credentials.count }

              expect(response).to have_http_status(422)
              expect(flash[:error]).to be_present

              existing = WebauthnCredential.find_by!(external_id: WebAuthn::Credential.from_create(new_webauthn_credential).id)
              expect(existing.user_id).to_not eq(user.id)
              expect(existing.reload.sign_count).to eq(0)
            end
          end
        end

        context 'when verification fails' do
          def post_rejected_registration(credential, challenge_value = challenge)
            @controller.session[:webauthn_challenge] = challenge_value
            webauthn_id = user.reload.webauthn_id
            credential_ids = user.webauthn_credentials.pluck(:id, :sign_count)

            post :create, params: { credential: credential, nickname: nickname }

            expect(response).to have_http_status(422)
            expect(body_as_json[:error]).to eq(I18n.t('webauthn_credentials.create.error'))
            expect(user.reload.webauthn_id).to eq(webauthn_id)
            expect(user.webauthn_credentials.pluck(:id, :sign_count)).to eq(credential_ids)
          end

          it 'does not store a credential when the challenge does not match' do
            post_rejected_registration(new_webauthn_credential, WebAuthn::Credential.options_for_get.challenge)
          end

          it 'does not store a credential from a different origin' do
            other_credential = WebAuthn::FakeClient.new('https://evil.example').create(challenge: challenge)

            post_rejected_registration(other_credential)
          end

          it 'does not store a credential for a different RP ID' do
            other_credential = fake_client.create(challenge: challenge, rp_id: 'evil.example')

            post_rejected_registration(other_credential)
          end

          it 'does not store a credential when the challenge is missing' do
            post_rejected_registration(new_webauthn_credential, nil)
          end

          it 'does not store a credential with inconsistent backup flags' do
            other_credential = fake_client.create(challenge: challenge, backup_eligibility: false, backup_state: true)

            post_rejected_registration(other_credential)
          end

          it 'does not store a credential whose id is longer than 1023 bytes' do
            authenticator = WebAuthn::FakeAuthenticator.new
            authenticator.define_singleton_method(:new_credential) do |_algorithm|
              [SecureRandom.random_bytes(1024), OpenSSL::PKey::EC.generate('prime256v1'), 0]
            end
            long_id_client = WebAuthn::FakeClient.new(domain, authenticator: authenticator)

            post_rejected_registration(long_id_client.create(challenge: challenge))
          end

          it 'keeps the webauthn id assigned by options when create fails' do
            get :options

            expect(user.reload.webauthn_id).to be_present
            post_rejected_registration(new_webauthn_credential, WebAuthn::Credential.options_for_get.challenge)
          end

          context 'when the user already has a security key' do
            let!(:existing_credential) { add_webauthn_credential(user) }

            before do
              user.update!(webauthn_id: WebAuthn.generate_user_id)
            end

            it 'does not change the stored credential when verification fails' do
              snapshot = existing_credential.reload.attributes.slice('user_id', 'external_id', 'public_key', 'sign_count')

              post_rejected_registration(new_webauthn_credential, WebAuthn::Credential.options_for_get.challenge)

              expect(existing_credential.reload.attributes.slice('user_id', 'external_id', 'public_key', 'sign_count')).to eq(snapshot)
            end
          end
        end

        context 'when user have not enabled webauthn' do
          context 'creation succeeds' do
            it 'creates a webauthn credential' do
              @controller.session[:webauthn_challenge] = challenge

              expect do
                post :create, params: { credential: new_webauthn_credential, nickname: nickname }
              end.to change { user.webauthn_credentials.count }.by(1)
            end
          end
        end

        context 'with a registration produced by webauthn 2.5.2' do
          include WebauthnLegacyFixture

          it 'stores the same credential id, public key, and sign count' do
            with_legacy_webauthn_origin do |fixture|
              stored = fixture.fetch('stored_credential')
              registration = fixture.fetch('registration')
              user.update!(webauthn_id: fixture.fetch('user_handle'))
              @controller.session[:webauthn_challenge] = registration.fetch('challenge')

              expect do
                post :create, params: { credential: registration.fetch('credential'), nickname: nickname }
              end.to change { user.webauthn_credentials.count }.by(1)

              expect(response).to have_http_status(200)
              created = user.webauthn_credentials.order(:id).last
              expect(created.external_id).to eq(stored.fetch('external_id'))
              expect(created.public_key).to eq(stored.fetch('public_key'))
              expect(created.sign_count).to eq(stored.fetch('sign_count'))
              expect(user.reload.webauthn_id).to eq(fixture.fetch('user_handle'))
            end
          end
        end
      end

      context 'when user has not enabled otp' do
        before do
          user.update(otp_required_for_login: false)
        end

        it 'requires otp enabled first' do
          post :create, params: { credential: new_webauthn_credential, nickname: nickname }

          expect(response).to redirect_to settings_two_factor_authentication_methods_path
          expect(flash[:error]).to be_present
        end
      end
    end

    context 'when not signed in' do
      it 'redirects to login' do
        post :create, params: { credential: new_webauthn_credential, nickname: nickname }

        expect(response).to redirect_to new_user_session_path
      end
    end
  end

  describe 'DELETE #destroy' do
    context 'when signed in' do
      before do
        sign_in user, scope: :user
      end

      context 'when user has otp enabled' do
        before do
          user.update(otp_required_for_login: true)
        end

        context 'when user has webauthn enabled' do
          before do
            user.update(webauthn_id: WebAuthn.generate_user_id)
            add_webauthn_credential(user)
          end

          context 'when deletion succeeds' do
            it 'redirects to 2FA methods list and shows flash success' do
              delete :destroy, params: { id: user.webauthn_credentials.take.id }

              expect(response).to redirect_to settings_two_factor_authentication_methods_path
              expect(flash[:success]).to be_present
            end

            it 'deletes the credential' do
              expect do
                delete :destroy, params: { id: user.webauthn_credentials.take.id }
              end.to change { user.webauthn_credentials.count }.by(-1)
            end
          end
        end

        context 'when user does not have webauthn enabled' do
          it 'redirects to 2FA methods list and shows flash error' do
            delete :destroy, params: { id: '1' }

            expect(response).to redirect_to settings_two_factor_authentication_methods_path
            expect(flash[:error]).to be_present
          end
        end
      end

      context 'when user does not have otp enabled' do
        it 'requires otp enabled first' do
          delete :destroy, params: { id: '1' }

          expect(response).to redirect_to settings_two_factor_authentication_methods_path
          expect(flash[:error]).to be_present
        end
      end
    end

    context 'when not signed in' do
      it 'redirects to login' do
        delete :destroy, params: { id: '1' }

        expect(response).to redirect_to new_user_session_path
      end
    end
  end
end
