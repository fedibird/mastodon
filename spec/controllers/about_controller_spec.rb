require 'rails_helper'

RSpec.describe AboutController, type: :controller do
  render_views

  before do
    stub_webpacker_manifest
  end

  describe 'GET #show' do
    before do
      get :show
    end

    it 'assigns @instance_presenter' do
      expect(assigns(:instance_presenter)).to be_kind_of InstancePresenter
    end

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end
  end

  describe 'GET #more' do
    before do
      get :more
    end

    it 'assigns @instance_presenter' do
      expect(assigns(:instance_presenter)).to be_kind_of InstancePresenter
    end

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end
  end

  describe 'GET #more with server rules' do
    it 'renders a rule hint under the rule text' do
      Rule.create!(text: 'Be kind', hint: 'Explain kindness')

      get :more

      expect(response).to have_http_status(200)
      expect(response.body).to include('Be kind')
      expect(response.body).to include('rules-list__hint')
      expect(response.body).to include('Explain kindness')
    end

    it 'does not render an empty hint' do
      Rule.create!(text: 'Be kind', hint: '')

      get :more

      expect(response).to have_http_status(200)
      expect(response.body).to include('Be kind')
      expect(response.body).not_to include('rules-list__hint')
    end
  end

  describe 'GET #terms' do
    before do
      get :terms
    end

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end
  end

  describe 'helper_method :new_user' do
    it 'returns a new User' do
      user = @controller.view_context.new_user
      expect(user).to be_kind_of User
      expect(user.account).to be_kind_of Account
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
