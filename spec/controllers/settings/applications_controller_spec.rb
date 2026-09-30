require 'rails_helper'

describe Settings::ApplicationsController do
  render_views

  let!(:user) { Fabricate(:user) }
  let!(:app) { Fabricate(:application, owner: user) }

  before do
    stub_webpacker_manifest
    sign_in user, scope: :user
  end

  describe 'GET #index' do
    let!(:other_app) { Fabricate(:application) }

    it 'shows apps' do
      get :index
      expect(response).to have_http_status(200)
      expect(assigns(:applications)).to include(app)
      expect(assigns(:applications)).to_not include(other_app)
    end
  end

  describe 'GET #show' do
    it 'returns http success' do
      get :show, params: { id: app.id }
      expect(response).to have_http_status(200)
      expect(assigns[:application]).to eql(app)
    end

    it 'returns 404 if you dont own app' do
      app.update!(owner: nil)

      get :show, params: { id: app.id }
      expect(response.status).to eq 404
    end
  end

  describe 'GET #new' do
    it 'defaults a new application to the profile scope' do
      get :new

      expect(response).to have_http_status(200)
      expect(assigns(:application).scopes.to_s).to eq 'profile'

      document = Nokogiri::HTML(response.body)
      profile = document.at_css('input[type="checkbox"][value="profile"]')
      expect(profile).to be_present
      expect(profile['checked']).to eq 'checked'
      expect(document.at_css('label[for="doorkeeper_application_scopes_profile"] .hint').text).to eq I18n.t('doorkeeper.scopes.profile')

      %w(read write follow).each do |scope|
        input = document.at_css(%(input[type="checkbox"][value="#{scope}"]))
        expect(input).to be_present
        expect(input['checked']).to be_nil
      end
    end
  end

  describe 'POST #create' do
    context 'success (passed scopes as a String)' do
      def call_create
        post :create, params: {
          doorkeeper_application: {
            name: 'My New App',
            redirect_uri: 'urn:ietf:wg:oauth:2.0:oob',
            website: 'http://google.com',
            scopes: 'read write follow'
          }
        }
        response
      end

      it 'creates an entry in the database' do
        expect { call_create }.to change(Doorkeeper::Application, :count)
      end

      it 'redirects back to applications page' do
        expect(call_create).to redirect_to(settings_applications_path)
      end
    end

    context 'success (passed scopes as an Array)' do
      def call_create
        post :create, params: {
          doorkeeper_application: {
            name: 'My New App',
            redirect_uri: 'urn:ietf:wg:oauth:2.0:oob',
            website: 'http://google.com',
            scopes: [ 'read', 'write', 'follow' ]
          }
        }
        response
      end

      it 'creates an entry in the database' do
        expect { call_create }.to change(Doorkeeper::Application, :count)
      end

      it 'redirects back to applications page' do
        expect(call_create).to redirect_to(settings_applications_path)
      end
    end

    context 'failure' do
      before do
        post :create, params: {
          doorkeeper_application: {
            name: '',
            redirect_uri: '',
            website: '',
            scopes: []
          }
        }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'renders form again' do
        expect(response).to render_template(:new)
      end
    end
  end

  describe 'PATCH #update' do
    context 'success' do
      let!(:token) { user.token_for_app(app) }
      let(:opts) {
        {
          website: 'https://foo.bar/'
        }
      }

      def call_update
        patch :update, params: {
          id: app.id,
          doorkeeper_application: opts
        }
        response
      end

      it 'updates existing application' do
        call_update
        expect(app.reload.website).to eql(opts[:website])
      end

      it 'redirects back to the application page' do
        expect(call_update).to redirect_to(settings_application_path(app))
        expect(flash[:notice]).to eq I18n.t('generic.changes_saved_msg')
      end

      it 'keeps the existing access token' do
        previous_scopes = token.scopes.to_s

        call_update

        expect(Doorkeeper::AccessToken.find_by(id: token.id)).to eq token
        expect(user.token_for_app(app).token).to eq token.token
        expect(user.token_for_app(app).scopes.to_s).to eq previous_scopes
      end
    end

    context 'when scopes change' do
      let!(:old_token) do
        app.update!(scopes: 'read')
        user.token_for_app(app)
      end

      it 'regenerates the access token with the new scopes' do
        patch :update, params: {
          id: app.id,
          doorkeeper_application: {
            scopes: 'profile',
          },
        }

        expect(app.reload.scopes.to_s).to eq 'profile'

        new_token = user.token_for_app(app)
        expect(Doorkeeper::AccessToken.find_by(id: old_token.id)).to be_nil
        expect(new_token.id).not_to eq old_token.id
        expect(new_token.token).not_to eq old_token.token
        expect(new_token.scopes.to_s).to eq 'profile'
        expect(response).to redirect_to(settings_application_path(app))
        expect(flash[:notice]).to eq I18n.t('applications.token_regenerated')
      end
    end

    context 'when the same scopes are saved again' do
      let!(:token) do
        app.update!(scopes: 'read')
        user.token_for_app(app)
      end

      it 'keeps the access token' do
        patch :update, params: {
          id: app.id,
          doorkeeper_application: {
            scopes: 'read',
          },
        }

        expect(app.reload.scopes.to_s).to eq 'read'
        expect(Doorkeeper::AccessToken.find_by(id: token.id)).to eq token
        expect(user.token_for_app(app).token).to eq token.token
        expect(response).to redirect_to(settings_application_path(app))
        expect(flash[:notice]).to eq I18n.t('generic.changes_saved_msg')
      end
    end

    context 'failure' do
      let!(:token) { user.token_for_app(app) }
      let!(:original_scopes) { app.scopes.to_s }

      before do
        patch :update, params: {
          id: app.id,
          doorkeeper_application: {
            name: '',
            redirect_uri: '',
            website: '',
            scopes: []
          }
        }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'renders form again' do
        expect(response).to render_template(:show)
      end

      it 'keeps the application scopes and access token' do
        expect(app.reload.scopes.to_s).to eq original_scopes
        expect(Doorkeeper::AccessToken.find_by(id: token.id)).to eq token
        expect(user.token_for_app(app).token).to eq token.token
      end
    end
  end

  describe 'destroy' do
    let(:redis_pipeline_stub) { instance_double(Redis::Namespace, publish: nil) }
    let!(:access_token) { Fabricate(:accessible_access_token, application: app) }

    before do
      allow(redis).to receive(:pipelined).and_yield(redis_pipeline_stub)
      post :destroy, params: { id: app.id }
    end

    it 'redirects back to applications page' do
      expect(response).to redirect_to(settings_applications_path)
    end

    it 'removes the app' do
      expect(Doorkeeper::Application.find_by(id: app.id)).to be_nil
    end

    it 'sends a session kill payload to the streaming server' do
      expect(redis_pipeline_stub).to have_received(:publish).with("timeline:access_token:#{access_token.id}", '{"event":"kill"}')
    end
  end

  describe 'regenerate' do
    let(:token) { user.token_for_app(app) }
    before do
      expect(token).to_not be_nil
      post :regenerate, params: { id: app.id }
    end

    it 'should create new token' do
      expect(user.token_for_app(app)).to_not eql(token)
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
