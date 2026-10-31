# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Settings group creation requests' do
  before do
    https!
    stub_webpacker_manifest
  end

  around do |example|
    Dir.mktmpdir do |dir|
      ClimateControl.modify(GROUP_CREATION_ICON_ROOT: dir, GROUP_CREATION_ICON_STORAGE: 'filesystem', S3_ENABLED: nil, SWIFT_ENABLED: nil, LOCAL_HTTPS: nil) do
        example.run
      end
    end
  end

  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'requester')) }

  def enable_requests!
    Setting.group_creation_requests = true
  end

  def saved_request(owner = user)
    GroupCreationRequest.where(requester_account_id: owner.account.id).order(:id).last
  end

  def upload(name = 'emojo.png', type = 'image/png')
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files', name), type)
  end

  def submit_form(username: 'freshgroup', display_name: 'Fresh Group', note: 'A local group', icon: upload, extra: {})
    post confirm_settings_group_creation_requests_path, params: {
      group_creation_request: {
        username: username,
        display_name: display_name,
        note: note,
        icon: icon,
      }.merge(extra),
    }
  end

  describe 'when the feature is off' do
    it 'rejects every route for anonymous and signed-in users' do
      paths = [
        settings_group_creation_requests_path,
        new_settings_group_creation_request_path,
        review_settings_group_creation_requests_path,
        draft_icon_settings_group_creation_requests_path,
      ]

      paths.each do |path|
        get path
        expect(response).to have_http_status(:not_found), path
      end

      sign_in user, scope: :user
      get settings_preferences_path
      expect(response.body).not_to include(I18n.t('settings.group_creation_requests'))

      paths.each do |path|
        get path
        expect(response).to have_http_status(:not_found), path
      end

      expect do
        submit_form
      end.not_to change(GroupCreationRequest, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'when the feature is on' do
    before { enable_requests! }

    it 'lets a normal local person submit, preview, and see only their own request' do
      sign_in user, scope: :user
      domain = Rails.configuration.x.local_domain

      get new_settings_group_creation_request_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('group_creation_requests.rules.owner'))
      expect(response.body).to include(I18n.t('group_creation_requests.rules.absent'))
      expect(response.body).to include(domain)
      expect(response.body).to include(I18n.t('settings.group_creation_requests'))
      expect(response.body).not_to include('name="previous_request_id"')
      expect(response.body).not_to include('name="group_creation_request[state]"')

      other_account_id = Fabricate(:user).account.id
      public_files = Dir.glob(Rails.public_path.join('**', '*'))

      submit_form(extra: { state: 'approved', requester_account_id: other_account_id, icon_storage_key: 'evil', decision_note: 'nope' })
      expect(response).to redirect_to(review_settings_group_creation_requests_path)
      follow_redirect!
      expect(response.body).to include("@freshgroup@#{domain}")
      expect(response.body).to include('Fresh Group')
      expect(response.body).to include(I18n.t('group_creation_requests.rules.owner'))
      expect(response.body).to include(draft_icon_settings_group_creation_requests_path)

      get draft_icon_settings_group_creation_requests_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq File.binread(Rails.root.join('spec/fixtures/files/emojo.png'))
      expect(response.headers['Cache-Control']).to eq 'private, no-store'
      expect(response.headers['X-Content-Type-Options']).to eq 'nosniff'
      expect(response.headers['Content-Disposition']).to include('inline')
      expect(response.headers['Content-Disposition']).to include('icon.png')
      expect(response.headers['Content-Disposition']).not_to include('emojo')

      expect do
        post settings_group_creation_requests_path, params: { confirmed: '0', state: 'approved', requester_account_id: 1 }
      end.not_to change(GroupCreationRequest, :count)
      expect(response.body).to include(I18n.t('group_creation_requests.errors.confirm_required'))

      expect do
        post settings_group_creation_requests_path, params: { confirmed: '1', state: 'approved' }
      end.not_to change { [Account.count, User.count, ManagedGroup.count, GroupRoleAssignment.count, Follow.count, Status.count, GroupAffiliation.count] }

      request = saved_request
      expect(request).to be_pending
      expect(request.requester_account).to eq user.account
      expect(request.reviewer_account).to be_nil
      expect(request.decision_note).to be_nil
      expect(request.username).to eq 'freshgroup'
      expect(request.icon_storage_key).to match(GroupCreationIcons::KEY_FORMAT)
      expect(user.account.reload.avatar_file_name).to be_nil
      expect(user.account.avatar_remote_url).to be_nil
      expect(Dir.glob(Rails.public_path.join('**', '*'))).to eq public_files

      path = GroupCreationIcons::Storage.resolve.local_path(request.icon_storage_key)
      expect(path.to_s).not_to start_with(Rails.public_path.to_s)

      get settings_group_creation_request_path(request)
      expect(response.body).to include("@freshgroup@#{domain}")
      expect(response.body).to include(I18n.t('group_creation_requests.states.pending'))

      get icon_settings_group_creation_request_path(request)
      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to eq 'private, no-store'
      expect(response.body.bytesize).to eq request.icon_byte_size

      post settings_group_creation_requests_path, params: { confirmed: '1' }
      expect(user.account.group_creation_requests.count).to eq 1

      other = Fabricate(:user)
      sign_in other, scope: :user
      get settings_group_creation_request_path(request)
      expect(response).to have_http_status(:not_found)
      get icon_settings_group_creation_request_path(request)
      expect(response).to have_http_status(:not_found)
      post cancel_settings_group_creation_request_path(request), params: { lock_version: request.lock_version }
      expect(response).to have_http_status(:not_found)
      expect(request.reload).to be_pending
    end

    it 'cancels only a pending request and survives a stale lock' do
      sign_in user, scope: :user
      submit_form
      follow_redirect!
      post settings_group_creation_requests_path, params: { confirmed: '1' }
      request = saved_request
      seen_version = request.lock_version

      request.update_columns(lock_version: seen_version + 1)
      post cancel_settings_group_creation_request_path(request), params: { lock_version: seen_version }
      expect(request.reload).to be_pending
      expect(response).to redirect_to(settings_group_creation_request_path(request))

      post cancel_settings_group_creation_request_path(request), params: { lock_version: request.lock_version }
      expect(request.reload).to be_cancelled
      expect(request.reviewer_account).to be_nil
      expect(request.icon_purged_at).to be_present
      expect(GroupCreationIcons::Storage.resolve.exist?(request.icon_storage_key)).to be false

      post cancel_settings_group_creation_request_path(request), params: { lock_version: request.lock_version }
      expect(request.reload).to be_cancelled
      expect(response).to redirect_to(settings_group_creation_request_path(request))
    end

    it 'reapplies from the requester’s own rejected or cancelled request only' do
      sign_in user, scope: :user
      submit_form(username: 'firstname', icon: nil)
      follow_redirect!
      post settings_group_creation_requests_path, params: { confirmed: '1' }
      original = saved_request
      original.record_cancellation!

      get new_settings_group_creation_request_path(previous_request_id: original.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('value="' + original.id.to_s + '"')
      expect(response.body).not_to include('type="text" name="previous_request_id"')

      post confirm_settings_group_creation_requests_path, params: {
        previous_request_id: original.id,
        group_creation_request: { username: 'secondname', display_name: 'Second', note: 'again' },
      }
      follow_redirect!
      post settings_group_creation_requests_path, params: { confirmed: '1' }
      successor = saved_request
      expect(successor.previous_request).to eq original
      expect(original.reload.username).to eq 'firstname'
      expect(successor.username).to eq 'secondname'

      get new_settings_group_creation_request_path(previous_request_id: original.id)
      expect(response).to have_http_status(:not_found)

      stranger = Fabricate(:user)
      foreign = GroupCreationRequest.create!(requester_account: stranger.account, username: 'foreignreq', display_name: 'Foreign', note: 'no')
      foreign.record_cancellation!
      get new_settings_group_creation_request_path(previous_request_id: foreign.id)
      expect(response).to have_http_status(:not_found)

      get new_settings_group_creation_request_path(previous_request_id: successor.id)
      expect(response).to have_http_status(:not_found)
    end

    it 'shows validation errors and does not reserve a pending username' do
      Fabricate(:account, username: 'takenname')
      sign_in user, scope: :user

      submit_form(username: 'takenname', icon: nil)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('activerecord.errors.models.group_creation_request.attributes.username.taken'))
      expect(GroupCreationRequest.count).to eq 0

      submit_form(username: 'Admin', icon: nil)
      expect(response.body).to include(I18n.t('activerecord.errors.models.group_creation_request.attributes.username.reserved'))

      submit_form(username: 'okname', display_name: 'あ' * 31, icon: nil)
      expect(response).to have_http_status(:ok)
      expect(GroupCreationRequest.count).to eq 0

      submit_form(username: 'sharedname', icon: nil)
      follow_redirect!
      post settings_group_creation_requests_path, params: { confirmed: '1' }
      other = Fabricate(:user)
      sign_in other, scope: :user
      submit_form(username: 'SHAREDNAME', icon: nil)
      follow_redirect!
      post settings_group_creation_requests_path, params: { confirmed: '1' }
      expect(GroupCreationRequest.where(username: 'sharedname').count).to eq 2
    end

    it 'rejects a spoofed or broken icon and does not leave a stored file' do
      sign_in user, scope: :user
      file = Tempfile.new(['icon', '.svg'])
      file.write('<svg xmlns="http://www.w3.org/2000/svg"></svg>')
      file.flush
      broken = Rack::Test::UploadedFile.new(file.path, 'image/jpeg', original_filename: 'icon.jpg')

      expect do
        submit_form(icon: broken)
      end.not_to change(GroupCreationRequest, :count)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('group_creation_requests.icon_errors.type_not_allowed')).or include(I18n.t('group_creation_requests.icon_errors.spoofed')).or include(I18n.t('group_creation_requests.icon_errors.corrupt'))
      expect(Dir.glob(File.join(ENV.fetch('GROUP_CREATION_ICON_ROOT'), '**', '*')).select { |path| File.file?(path) }).to be_empty
    ensure
      file.close!
    end

    it 'rejects an icon upload when private storage is not configured and still accepts a request without one' do
      sign_in user, scope: :user
      ClimateControl.modify(S3_ENABLED: 'true', GROUP_CREATION_ICON_STORAGE: nil) do
        submit_form
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('group_creation_requests.icon_errors.storage_unavailable'))
        expect(GroupCreationRequest.count).to eq 0

        submit_form(username: 'noicon', icon: nil)
        expect(response).to redirect_to(review_settings_group_creation_requests_path)
      end
    end

    it 'refuses a group account and a suspended person' do
      group_user = Fabricate(:user, account: Fabricate(:account, username: 'grouplogin', actor_type: 'Group'))
      sign_in group_user, scope: :user
      get settings_group_creation_requests_path
      expect(response).to have_http_status(:forbidden)

      suspended = Fabricate(:user)
      suspended.account.update_columns(suspended_at: Time.now.utc)
      sign_in suspended, scope: :user
      get new_settings_group_creation_request_path
      expect(response).to redirect_to(edit_user_registration_path)
    end

    it 'discards an icon draft when the same session authenticates as someone else' do
      sign_in user, scope: :user
      submit_form(username: 'alicedraft', display_name: 'Alice Only', note: 'only-alice-sees-this')
      expect(response).to redirect_to(review_settings_group_creation_requests_path)

      other = Fabricate(:user)
      sign_in other, scope: :user
      get review_settings_group_creation_requests_path
      expect(response).to redirect_to(new_settings_group_creation_request_path)
      follow_redirect!
      expect(response.body).not_to include('only-alice-sees-this')

      get draft_icon_settings_group_creation_requests_path
      expect(response).to have_http_status(:not_found)

      expect do
        post settings_group_creation_requests_path, params: { confirmed: '1' }
      end.not_to change(GroupCreationRequest, :count)
      expect(GroupCreationRequest.where(requester_account_id: other.account.id)).to be_empty
      expect(Dir.glob(File.join(ENV.fetch('GROUP_CREATION_ICON_ROOT'), '**', '*')).select { |path| File.file?(path) }).to be_empty
    end

    it 'renders the Japanese explanation for a Japanese user' do
      user.update!(locale: 'ja')
      sign_in user, scope: :user
      get new_settings_group_creation_request_path

      expect(response.body).to include('初代オーナー')
      expect(response.body).to include('グループは存在しません')
      expect(response.body).to include(Rails.configuration.x.local_domain)
    end

    it 'shows a rejection reason only to the requester' do
      load Rails.root.join('db', 'seeds', '03_roles.rb')
      sign_in user, scope: :user
      submit_form(icon: nil)
      follow_redirect!
      post settings_group_creation_requests_path, params: { confirmed: '1' }
      request = saved_request
      reviewer = user_with_role('Owner')
      request.record_rejection!(reviewer_account: reviewer.account, decision_note: '名前が曖昧です')

      get settings_group_creation_request_path(request)
      expect(response.body).to include('名前が曖昧です')
      expect(response.body).to include(new_settings_group_creation_request_path(previous_request_id: request.id))

      sign_in reviewer, scope: :user
      get settings_group_creation_request_path(request)
      expect(response).to have_http_status(:not_found)
    end
  end
end
