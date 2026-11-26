# frozen_string_literal: true

require 'rails_helper'
require 'webauthn/fake_client'

RSpec.describe Auth::SessionsController, type: :controller do
  render_views

  before do
    request.env['devise.mapping'] = Devise.mappings[:user]
  end

  describe 'GET #new' do
    it 'returns http success' do
      get :new
      expect(response).to have_http_status(200)
    end
  end

  describe 'DELETE #destroy' do
    let(:user) { Fabricate(:user) }

    context 'with a regular user' do
      it 'redirects to home after sign out' do
        sign_in(user, scope: :user)
        delete :destroy

        expect(response).to redirect_to(new_user_session_path)
      end

      it 'does not delete redirect location with continue=true' do
        sign_in(user, scope: :user)
        controller.store_location_for(:user, '/authorize')
        delete :destroy, params: { continue: 'true' }
        expect(controller.stored_location_for(:user)).to eq '/authorize'
      end
    end

    context 'with a suspended user' do
      it 'redirects to home after sign out' do
        Fabricate(:account, user: user, suspended: true)
        sign_in(user, scope: :user)
        delete :destroy

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'POST #create' do
    context 'using PAM authentication', if: ENV['PAM_ENABLED'] == 'true' do
      context 'using a valid password' do
        before do
          post :create, params: { user: { email: "pam_user1", password: '123456' } }
        end

        it 'redirects to home' do
          expect(response).to redirect_to(root_path)
        end

        it 'logs the user in' do
          expect(controller.current_user).to be_instance_of(User)
        end
      end

      context 'using an invalid password' do
        before do
          post :create, params: { user: { email: "pam_user1", password: 'WRONGPW' } }
        end

        it 'shows a login error' do
          expect(flash[:alert]).to match I18n.t('devise.failure.invalid', authentication_keys: I18n.t('activerecord.attributes.user.email'))
        end

        it "doesn't log the user in" do
          expect(controller.current_user).to be_nil
        end
      end

      context 'using a valid email and existing user' do
        let(:user) do
          account = Fabricate.build(:account, username: 'pam_user1')
          account.save!(validate: false)
          user = Fabricate(:user, email: 'pam@example.com', password: nil, account: account, external: true)
          user
        end

        before do
          post :create, params: { user: { email: user.email, password: '123456' } }
        end

        it 'redirects to home' do
          expect(response).to redirect_to(root_path)
        end

        it 'logs the user in' do
          expect(controller.current_user).to eq user
        end
      end
    end

    context 'using password authentication' do
      let(:user) { Fabricate(:user, email: 'foo@bar.com', password: 'abcdefgh') }

      context 'using a valid password' do
        before do
          post :create, params: { user: { email: user.email, password: user.password } }
        end

        it 'redirects to home' do
          expect(response).to redirect_to(root_path)
        end

        it 'logs the user in' do
          expect(controller.current_user).to eq user
        end
      end

      context 'using email with uppercase letters' do
        before do
          post :create, params: { user: { email: user.email.upcase, password: user.password } }
        end

        it 'redirects to home' do
          expect(response).to redirect_to(root_path)
        end

        it 'logs the user in' do
          expect(controller.current_user).to eq user
        end
      end

      context 'using an invalid password' do
        before do
          post :create, params: { user: { email: user.email, password: 'wrongpw' } }
        end

        it 'shows a login error' do
          expect(flash[:alert]).to match I18n.t('devise.failure.invalid', authentication_keys: I18n.t('activerecord.attributes.user.email'))
        end

        it "doesn't log the user in" do
          expect(controller.current_user).to be_nil
        end
      end

      context 'using an unconfirmed password' do
        before do
          request.headers['Accept-Language'] = accept_language
          post :create, params: { user: { email: unconfirmed_user.email, password: unconfirmed_user.password } }
        end

        let(:unconfirmed_user) { user.tap { |u| u.update!(confirmed_at: nil) } }
        let(:accept_language) { 'fr' }

        it 'redirects to home' do
          expect(response).to redirect_to(root_path)
        end
      end

      context "logging in from the user's page" do
        before do
          allow(controller).to receive(:single_user_mode?).and_return(single_user_mode)
          allow(controller).to receive(:stored_location_for).with(:user).and_return("/@#{user.account.username}")
          post :create, params: { user: { email: user.email, password: user.password } }
        end

        context "in single user mode" do
          let(:single_user_mode) { true }

          it 'redirects to home' do
            expect(response).to redirect_to(root_path)
          end
        end

        context "in non-single user mode" do
          let(:single_user_mode) { false }

          it "redirects back to the user's page" do
            expect(response).to redirect_to(short_account_path(username: user.account))
          end
        end
      end
    end

    context 'using two-factor authentication' do
      context 'with OTP enabled as second factor' do
        let!(:user) do
          Fabricate(:user, email: 'x@y.com', password: 'abcdefgh', otp_required_for_login: true, otp_secret: User.generate_otp_secret(32))
        end

        let!(:recovery_codes) do
          codes = user.generate_otp_backup_codes!
          user.save
          return codes
        end

        context 'using email and password' do
          before do
            post :create, params: { user: { email: user.email, password: user.password } }
          end

          it 'renders two factor authentication page' do
            expect(controller).to render_template("two_factor")
            expect(controller).to render_template(partial: "_otp_authentication_form")
          end
        end

        context 'using upcase email and password' do
          before do
            post :create, params: { user: { email: user.email.upcase, password: user.password } }
          end

          it 'renders two factor authentication page' do
            expect(controller).to render_template("two_factor")
            expect(controller).to render_template(partial: "_otp_authentication_form")
          end
        end

        context 'when repeatedly using an invalid TOTP code before using a valid code' do
          before do
            stub_const('Auth::SessionsController::MAX_2FA_ATTEMPTS_PER_HOUR', 2)
          end

          it 'does not log the user in' do
            # Travel to the beginning of an hour to avoid crossing rate-limit buckets
            travel_to '2023-12-20T10:00:00Z'

            Auth::SessionsController::MAX_2FA_ATTEMPTS_PER_HOUR.times do
              post :create, params: { user: { otp_attempt: '1234' } }, session: { attempt_user_id: user.id, attempt_user_updated_at: user.updated_at.to_s }
              expect(controller.current_user).to be_nil
            end

            post :create, params: { user: { otp_attempt: user.current_otp } }, session: { attempt_user_id: user.id, attempt_user_updated_at: user.updated_at.to_s }
            expect(controller.current_user).to be_nil
            expect(flash[:alert]).to match I18n.t('users.rate_limited')
          end
        end

        context 'when using a valid OTP' do
          before do
            post :create, params: { user: { otp_attempt: user.current_otp } }, session: { attempt_user_id: user.id, attempt_user_updated_at: user.updated_at.to_s }
          end

          it 'redirects to home' do
            expect(response).to redirect_to(root_path)
          end

          it 'logs the user in' do
            expect(controller.current_user).to eq user
          end
        end

        context 'when the server has an decryption error' do
          before do
            allow_any_instance_of(User).to receive(:validate_and_consume_otp!).and_raise(OpenSSL::Cipher::CipherError)
            post :create, params: { user: { otp_attempt: user.current_otp } }, session: { attempt_user_id: user.id, attempt_user_updated_at: user.updated_at.to_s }
          end

          it 'shows a login error' do
            expect(flash[:alert]).to match I18n.t('users.invalid_otp_token')
          end

          it "doesn't log the user in" do
            expect(controller.current_user).to be_nil
          end
        end

        context 'using a valid recovery code' do
          before do
            post :create, params: { user: { otp_attempt: recovery_codes.first } }, session: { attempt_user_id: user.id, attempt_user_updated_at: user.updated_at.to_s }
          end

          it 'redirects to home' do
            expect(response).to redirect_to(root_path)
          end

          it 'logs the user in' do
            expect(controller.current_user).to eq user
          end
        end

        context 'using an invalid OTP' do
          before do
            post :create, params: { user: { otp_attempt: 'wrongotp' } }, session: { attempt_user_id: user.id, attempt_user_updated_at: user.updated_at.to_s }
          end

          it 'shows a login error' do
            expect(flash[:alert]).to match I18n.t('users.invalid_otp_token')
          end

          it "doesn't log the user in" do
            expect(controller.current_user).to be_nil
          end
        end
      end

      context 'with WebAuthn and OTP enabled as second factor' do
        let!(:user) do
          Fabricate(:user, email: 'x@y.com', password: 'abcdefgh', otp_required_for_login: true, otp_secret: User.generate_otp_secret(32))
        end

        let!(:recovery_codes) do
          codes = user.generate_otp_backup_codes!
          user.save
          return codes
        end

        let!(:webauthn_credential) do
          user.update(webauthn_id: WebAuthn.generate_user_id)
          public_key_credential = WebAuthn::Credential.from_create(fake_client.create)
          user.webauthn_credentials.create(
            nickname: 'SecurityKeyNickname',
            external_id: public_key_credential.id,
            public_key: public_key_credential.public_key,
            sign_count: '1000'
           )
          user.webauthn_credentials.take
        end

        let(:domain) { "#{Rails.configuration.x.use_https ? 'https' : 'http' }://#{Rails.configuration.x.web_domain}" }

        let(:authenticator) { WebAuthn::FakeAuthenticator.new }
        let(:fake_client) { WebAuthn::FakeClient.new(domain, authenticator: authenticator) }

        let(:challenge) { WebAuthn::Credential.options_for_get.challenge }

        let(:sign_count) { 1234 }

        let(:fake_credential) { fake_client.get(challenge: challenge, sign_count: sign_count) }

        context 'using email and password' do
          before do
            post :create, params: { user: { email: user.email, password: user.password } }
          end

          it 'renders webauthn authentication page' do
            expect(controller).to render_template("two_factor")
            expect(controller).to render_template(partial: "_webauthn_form")
          end
        end

        context 'using upcase email and password' do
          before do
            post :create, params: { user: { email: user.email.upcase, password: user.password } }
          end

          it 'renders webauthn authentication page' do
            expect(controller).to render_template("two_factor")
            expect(controller).to render_template(partial: "_webauthn_form")
          end
        end

        context 'using a valid webauthn credential' do
          before do
            @controller.session[:webauthn_challenge] = challenge

            post :create, params: { user: { credential: fake_credential } }, session: { attempt_user_id: user.id, attempt_user_updated_at: user.updated_at.to_s }
          end

          it 'instructs the browser to redirect to home' do
            expect(body_as_json[:redirect_path]).to eq(root_path)
          end

          it 'logs the user in' do
            expect(controller.current_user).to eq user
          end

          it 'updates the sign count' do
            expect(webauthn_credential.reload.sign_count).to eq(sign_count)
          end
        end

        context 'when the webauthn ceremony does not verify' do
          def post_webauthn(credential, challenge_value = challenge)
            @controller.session[:webauthn_challenge] = challenge_value

            post :create, params: { user: { credential: credential } }, session: { attempt_user_id: user.id, attempt_user_updated_at: user.updated_at.to_s }
          end

          it 'rejects a mismatched challenge without signing in or changing the credential' do
            other_challenge = WebAuthn::Credential.options_for_get.challenge
            bad_credential = fake_client.get(challenge: other_challenge, sign_count: sign_count)

            post_webauthn(bad_credential)

            expect(response).to have_http_status(422)
            expect(controller.current_user).to be_nil
            expect(webauthn_credential.reload.sign_count).to eq(1000)
          end

          it 'rejects a different origin' do
            webauthn_credential
            other_client = WebAuthn::FakeClient.new('https://evil.example', authenticator: authenticator)
            bad_credential = other_client.get(challenge: challenge, rp_id: URI.parse(domain).host, sign_count: sign_count)

            post_webauthn(bad_credential)

            expect(response).to have_http_status(422)
            expect(controller.current_user).to be_nil
            expect(webauthn_credential.reload.sign_count).to eq(1000)
          end

          it 'rejects a different RP ID' do
            webauthn_credential
            credentials = authenticator.instance_variable_get(:@credentials)
            credentials['evil.example'] = credentials.fetch(URI.parse(domain).host)
            bad_credential = fake_client.get(challenge: challenge, rp_id: 'evil.example', sign_count: sign_count)

            post_webauthn(bad_credential)

            expect(response).to have_http_status(422)
            expect(controller.current_user).to be_nil
            expect(webauthn_credential.reload.sign_count).to eq(1000)
          end

          it 'rejects a signature from a different key' do
            other_client = WebAuthn::FakeClient.new(domain)
            WebAuthn::Credential.from_create(other_client.create)
            forged = other_client.get(challenge: challenge, sign_count: sign_count)
            forged['id'] = webauthn_credential.external_id
            forged['rawId'] = webauthn_credential.external_id

            post_webauthn(forged)

            expect(response).to have_http_status(422)
            expect(controller.current_user).to be_nil
            expect(webauthn_credential.reload.sign_count).to eq(1000)
          end

          it 'rejects a sign count that does not increase' do
            stale = fake_client.get(challenge: challenge, sign_count: 1000)

            post_webauthn(stale)

            expect(response).to have_http_status(422)
            expect(controller.current_user).to be_nil
            expect(webauthn_credential.reload.sign_count).to eq(1000)
          end

          it 'rejects inconsistent backup flags' do
            bad_credential = fake_client.get(
              challenge: challenge,
              sign_count: sign_count,
              backup_eligibility: false,
              backup_state: true
            )

            post_webauthn(bad_credential)

            expect(response).to have_http_status(422)
            expect(controller.current_user).to be_nil
            expect(webauthn_credential.reload.sign_count).to eq(1000)
          end

          it 'rejects a missing challenge' do
            post_webauthn(fake_credential, nil)

            expect(response).to have_http_status(422)
            expect(controller.current_user).to be_nil
            expect(webauthn_credential.reload.sign_count).to eq(1000)
          end

          # find_by! is outside the WebAuthn rescue. ApplicationController turns
          # the missing credential into the existing 404, without signing in or
          # updating either sign count.
          it 'does not accept another user credential' do
            other_user = Fabricate(:user, otp_required_for_login: true, otp_secret: User.generate_otp_secret(32))
            other_user.update!(webauthn_id: WebAuthn.generate_user_id)
            other_client = WebAuthn::FakeClient.new(domain)
            other_public = WebAuthn::Credential.from_create(other_client.create)
            other_user.webauthn_credentials.create!(
              nickname: 'Other Key',
              external_id: other_public.id,
              public_key: other_public.public_key,
              sign_count: 0
            )
            other_assertion = other_client.get(challenge: challenge, sign_count: 1)

            post_webauthn(other_assertion)

            expect(response).to have_http_status(404)
            expect(controller.current_user).to be_nil
            expect(webauthn_credential.reload.sign_count).to eq(1000)
            expect(other_user.webauthn_credentials.take.reload.sign_count).to eq(0)
          end
        end
      end

      context 'with a credential registered by webauthn 2.5.2' do
        include WebauthnLegacyFixture

        let!(:user) do
          Fabricate(:user, email: 'legacy-webauthn@example.com', password: 'abcdefgh', otp_required_for_login: true, otp_secret: User.generate_otp_secret(32))
        end

        def store_legacy_credential!(fixture)
          stored = fixture.fetch('stored_credential')
          user.update!(webauthn_id: fixture.fetch('user_handle'))
          user.webauthn_credentials.create!(
            nickname: 'Legacy Key',
            external_id: stored.fetch('external_id'),
            public_key: stored.fetch('public_key'),
            sign_count: stored.fetch('sign_count')
          )
        end

        def post_legacy_assertion!(fixture, assertion)
          record = store_legacy_credential!(fixture)
          @controller.session[:webauthn_challenge] = assertion.fetch('challenge')

          post :create, params: { user: { credential: assertion.fetch('credential') } }, session: { attempt_user_id: user.id, attempt_user_updated_at: user.updated_at.to_s }

          record
        end

        it 'signs in and updates the sign count' do
          with_legacy_webauthn_origin do |fixture|
            assertion = fixture.fetch('assertion')
            record = post_legacy_assertion!(fixture, assertion)

            expect(response).to have_http_status(200)
            expect(body_as_json[:redirect_path]).to eq(root_path)
            expect(controller.current_user).to eq(user)
            expect(record.reload.sign_count).to eq(assertion.fetch('sign_count'))
          end
        end

        it 'signs in when clientData still contains tokenBinding' do
          with_legacy_webauthn_origin do |fixture|
            assertion = fixture.fetch('token_binding_assertion')
            record = post_legacy_assertion!(fixture, assertion)

            expect(response).to have_http_status(200)
            expect(controller.current_user).to eq(user)
            expect(record.reload.sign_count).to eq(assertion.fetch('sign_count'))
          end
        end
      end
    end

    context 'when 2FA is disabled and IP is unfamiliar' do
      let!(:user) { Fabricate(:user, email: 'x@y.com', password: 'abcdefgh', current_sign_in_at: 3.weeks.ago, current_sign_in_ip: '0.0.0.0') }

      before do
        request.remote_ip  = '10.10.10.10'
        request.user_agent = 'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:75.0) Gecko/20100101 Firefox/75.0'

        allow(UserMailer).to receive(:sign_in_token).and_return(double('email', deliver_later!: nil))
      end

      context 'using email and password' do
        before do
          post :create, params: { user: { email: user.email, password: user.password } }
        end

        it 'renders sign in token authentication page' do
          expect(controller).to render_template("sign_in_token")
        end

        it 'generates sign in token' do
          expect(user.reload.sign_in_token).to_not be_nil
        end

        it 'sends sign in token e-mail' do
          expect(UserMailer).to have_received(:sign_in_token)
        end
      end

      context 'using a valid sign in token' do
        before do
          user.generate_sign_in_token && user.save
          post :create, params: { user: { sign_in_token_attempt: user.sign_in_token } }, session: { attempt_user_id: user.id, attempt_user_updated_at: user.updated_at.to_s }
        end

        it 'redirects to home' do
          expect(response).to redirect_to(root_path)
        end

        it 'logs the user in' do
          expect(controller.current_user).to eq user
        end
      end

      context 'using an invalid sign in token' do
        before do
          post :create, params: { user: { sign_in_token_attempt: 'wrongotp' } }, session: { attempt_user_id: user.id, attempt_user_updated_at: user.updated_at.to_s }
        end

        it 'shows a login error' do
          expect(flash[:alert]).to match I18n.t('users.invalid_sign_in_token')
        end

        it "doesn't log the user in" do
          expect(controller.current_user).to be_nil
        end
      end
    end
  end

  describe 'GET #webauthn_options' do
    let(:user) { Fabricate(:user, email: 'x@y.com', password: 'abcdefgh') }
    let(:domain) { "#{Rails.configuration.x.use_https ? 'https' : 'http' }://#{Rails.configuration.x.web_domain}" }

    it 'returns 401 when the attempt user has no security key' do
      get :webauthn_options, session: { attempt_user_id: user.id }

      expect(response).to have_http_status(401)
      expect(body_as_json[:error]).to eq(I18n.t('webauthn_credentials.not_enabled'))
    end

    it 'returns 401 when the attempt user does not exist' do
      get :webauthn_options, session: { attempt_user_id: 0 }

      expect(response).to have_http_status(401)
    end

    it 'returns a challenge for a registered security key without changing it' do
      fake_client = WebAuthn::FakeClient.new(domain)
      user.update!(otp_required_for_login: true, webauthn_id: WebAuthn.generate_user_id)
      public_key_credential = WebAuthn::Credential.from_create(fake_client.create)
      credential = user.webauthn_credentials.create!(
        nickname: 'SecurityKeyNickname',
        external_id: public_key_credential.id,
        public_key: public_key_credential.public_key,
        sign_count: 4
      )

      get :webauthn_options, session: { attempt_user_id: user.id }

      body = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(body['timeout']).to eq(120_000)
      expect(body['challenge']).to eq(@controller.session[:webauthn_challenge])
      expect(body['allowCredentials'].map { |item| item['id'] }).to eq([credential.external_id])
      expect(credential.reload.sign_count).to eq(4)
      expect(user.reload.webauthn_id).to be_present
    end
  end
end
