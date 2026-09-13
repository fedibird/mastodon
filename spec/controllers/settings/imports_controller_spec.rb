require 'rails_helper'

RSpec.describe Settings::ImportsController, type: :controller do
  render_views

  before do
    sign_in Fabricate(:user), scope: :user
  end

  describe "GET #show" do
    def stub_webpack_manifest
      # Render the settings/admin layout without the compiled webpack manifest
      # (not built in this test env; CI precompiles packs). Stub the manifest
      # lookup at its single root so every pack helper resolves to a dummy path.
      manifest = Webpacker.instance.manifest
      resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
      allow(manifest).to receive(:lookup!, &resolver)
      allow(manifest).to receive(:lookup, &resolver)
    end

    before { stub_webpack_manifest }

    it "returns http success" do
      get :show
      expect(response).to have_http_status(200)
    end

    it 'renders recent follow-import progress for the current account' do

      user = Fabricate(:user)
      sign_in user, scope: :user
      batch = FollowImportBatch.create!(subject: ModerationSubject.for_account!(user.account), imported_at: Time.now.utc,
                                        mode: :merge, target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
      batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 0, state: :accepted)

      get :show

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('imports.follow_progress.title'))
    end

    it 'shows a follow import with no batch as preparing (CSV retained until a batch is recorded)' do
      user = Fabricate(:user)
      sign_in user, scope: :user
      Import.create!(account: user.account, type: 'following', data: attachment_fixture('new-following-imports.txt'))

      get :show

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('imports.follow_progress.title'))
      expect(response.body).to include(I18n.t('imports.follow_progress.status.preparing'))
      expect(response.body).not_to include(I18n.t('imports.follow_progress.status.completed'))
    end

    it 'does not list a leftover follow import as preparing once its batch exists' do
      user = Fabricate(:user)
      sign_in user, scope: :user
      import = Import.create!(account: user.account, type: 'following', data: attachment_fixture('new-following-imports.txt'))
      batch = FollowImportBatch.create!(subject: ModerationSubject.for_account!(user.account), import_id: import.id,
                                        imported_at: Time.now.utc, mode: :merge, target_count: 1,
                                        resolved_target_count: 1, unresolved_target_count: 0)
      batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 0, state: :accepted)

      get :show

      expect(response.body).to include(I18n.t('imports.follow_progress.status.completed'))
      expect(response.body).not_to include(I18n.t('imports.follow_progress.status.preparing'))
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
