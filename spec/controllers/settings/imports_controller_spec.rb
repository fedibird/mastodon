require 'rails_helper'

RSpec.describe Settings::ImportsController, type: :controller do
  render_views

  before do
    sign_in Fabricate(:user), scope: :user
  end

  describe "GET #show" do
    it "returns http success" do
      get :show
      expect(response).to have_http_status(200)
    end
  end

  describe 'POST #create' do
    it 'redirects to settings path with successful following import' do
      service = double(call: nil)
      allow(ResolveAccountService).to receive(:new).and_return(service)
      post :create, params: {
        import: {
          type: 'following',
          data: fixture_file_upload('imports.txt')
        }
      }

      expect(response).to redirect_to(settings_import_path)
    end

    it 'redirects to settings path with successful blocking import' do
      service = double(call: nil)
      allow(ResolveAccountService).to receive(:new).and_return(service)
      post :create, params: {
        import: {
          type: 'blocking',
          data: fixture_file_upload('imports.txt')
        }
      }

      expect(response).to redirect_to(settings_import_path)
    end

    it 'routes a follow import to the retryable follow-import processor' do
      allow(FollowImport::ProcessImportWorker).to receive(:perform_async)
      allow(ImportWorker).to receive(:perform_async)

      post :create, params: { import: { type: 'following', data: fixture_file_upload('imports.txt') } }

      expect(FollowImport::ProcessImportWorker).to have_received(:perform_async)
      expect(ImportWorker).not_to have_received(:perform_async)
    end

    it 'routes a non-follow import to ImportWorker' do
      allow(FollowImport::ProcessImportWorker).to receive(:perform_async)
      allow(ImportWorker).to receive(:perform_async)

      post :create, params: { import: { type: 'blocking', data: fixture_file_upload('imports.txt') } }

      expect(ImportWorker).to have_received(:perform_async)
      expect(FollowImport::ProcessImportWorker).not_to have_received(:perform_async)
    end
  end
end
