# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Settings::ImportsController, type: :controller do
  render_views

  before do
    sign_in Fabricate(:user), scope: :user
  end

  describe 'GET #show' do
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

    it 'returns http success' do
      get :show
      expect(response).to have_http_status(200)
    end

    it 'renders recent follow-import progress for the current account' do
      user = Fabricate(:user)
      sign_in user, scope: :user
      imported_at = Time.utc(2026, 9, 21, 7, 30, 0)
      batch = FollowImportBatch.create!(subject: ModerationSubject.for_account!(user.account), imported_at: imported_at,
                                        mode: :merge, target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
      batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 0, state: :accepted)

      get :show

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('imports.follow_progress.title'))
      expect(response.body).to include(%(<time class="formatted" datetime="#{imported_at.iso8601}"></time>))
    end

    it 'shows a marked follow import with no batch as preparing (CSV retained until a batch is recorded)' do
      user = Fabricate(:user)
      sign_in user, scope: :user
      Import.create!(account: user.account, type: 'following', data: attachment_fixture('new-following-imports.txt'),
                     follow_import_pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)

      get :show

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('imports.follow_progress.title'))
      expect(response.body).to include(I18n.t('imports.follow_progress.status.preparing'))
      expect(response.body).not_to include(I18n.t('imports.follow_progress.status.completed'))
    end

    it 'does not list an unmarked leftover follow import as preparing' do
      user = Fabricate(:user)
      sign_in user, scope: :user
      Import.create!(account: user.account, type: 'following', data: attachment_fixture('new-following-imports.txt'))

      get :show

      expect(response).to have_http_status(200)
      expect(response.body).not_to include(I18n.t('imports.follow_progress.status.preparing'))
    end

    it 'does not list an unknown pipeline version as preparing' do
      user = Fabricate(:user)
      sign_in user, scope: :user
      Import.create!(account: user.account, type: 'following', data: attachment_fixture('new-following-imports.txt'),
                     follow_import_pipeline_version: 2)

      get :show

      expect(response).to have_http_status(200)
      expect(response.body).not_to include(I18n.t('imports.follow_progress.status.preparing'))
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

    it 'shows a review_required import as waiting for review without evidence' do
      user = Fabricate(:user)
      sign_in user, scope: :user
      batch = FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(user.account),
        imported_at: Time.now.utc,
        mode: :merge,
        preflight_state: :review_required,
        target_count: 1,
        resolved_target_count: 0,
        unresolved_target_count: 1,
        metadata: { 'sockpuppet-signal' => 'hidden-evidence' }
      )
      batch.targets.create!(target_key_hash: 'secret-target-hash-xyz', position: 0, state: :pending)

      get :show

      expect(response.body).to include(I18n.t('imports.follow_progress.status.waiting_for_review'))
      expect(response.body).not_to include('secret-target-hash-xyz')
      expect(response.body).not_to include('hidden-evidence')
      expect(response.body).not_to include('sockpuppet-signal')
    end

    it 'shows a stopped import as stopped with no active waiting count' do
      user = Fabricate(:user)
      sign_in user, scope: :user
      batch = FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(user.account),
        imported_at: Time.now.utc,
        mode: :merge,
        preflight_state: :stopped,
        target_count: 1,
        resolved_target_count: 0,
        unresolved_target_count: 1
      )
      batch.targets.create!(target_key_hash: 'still-pending', position: 0, state: :pending)

      get :show

      row = Nokogiri::HTML(response.body).css('tr').find { |tr| tr.text.include?(I18n.t('imports.follow_progress.status.stopped')) }
      cells = row.css('td').map { |td| td.text.strip }
      expect(cells[1]).to eq I18n.t('imports.follow_progress.status.stopped')
      expect(cells[3]).to eq '0'
      expect(response.body).not_to include(I18n.t('imports.follow_progress.status.in_progress'))
    end
  end

  describe 'POST #create' do
    it 'redirects to settings path with successful following import' do
      service = double(call: nil)
      allow(ResolveAccountService).to receive(:new).and_return(service)
      post :create, params: {
        import: {
          type: 'following',
          data: fixture_file_upload('imports.txt'),
        },
      }

      expect(response).to redirect_to(settings_import_path)
    end

    it 'redirects to settings path with successful blocking import' do
      service = double(call: nil)
      allow(ResolveAccountService).to receive(:new).and_return(service)
      post :create, params: {
        import: {
          type: 'blocking',
          data: fixture_file_upload('imports.txt'),
        },
      }

      expect(response).to redirect_to(settings_import_path)
    end

    it 'persists the follow-import pipeline marker before enqueueing the processor' do
      allow(FollowImport::ProcessImportWorker).to receive(:perform_async) do |import_id|
        expect(Import.find(import_id).follow_import_pipeline_version).to eq Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION
      end
      allow(ImportWorker).to receive(:perform_async)

      expect { post :create, params: { import: { type: 'following', data: fixture_file_upload('imports.txt') } } }
        .to change(Import, :count).by(1)

      expect(FollowImport::ProcessImportWorker).to have_received(:perform_async)
      expect(ImportWorker).not_to have_received(:perform_async)
      expect(Import.order(:id).last.follow_import_pipeline_version).to eq Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION
    end

    it 'does not stamp a pipeline marker on a non-follow import' do
      allow(FollowImport::ProcessImportWorker).to receive(:perform_async)
      allow(ImportWorker).to receive(:perform_async)

      post :create, params: { import: { type: 'blocking', data: fixture_file_upload('imports.txt') } }

      expect(ImportWorker).to have_received(:perform_async)
      expect(FollowImport::ProcessImportWorker).not_to have_received(:perform_async)
      expect(Import.order(:id).last.follow_import_pipeline_version).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
