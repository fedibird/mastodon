# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin group administration' do
  before do
    https!
    stub_webpacker_manifest
    load Rails.root.join('db', 'seeds', '03_roles.rb')
  end

  around do |example|
    previous = {
      requests: Setting.group_creation_requests,
      enabled: Setting.group_registration_invites_enabled,
      quota: Setting.group_registration_invites_shared_quota,
      quota_unlimited: Setting.group_registration_invites_shared_quota_unlimited,
      max_uses: Setting.group_registration_invites_per_link_max_uses,
      unlimited_uses: Setting.group_registration_invites_per_link_unlimited_uses,
      lifetime: Setting.group_registration_invites_per_link_lifetime_seconds,
      indefinite: Setting.group_registration_invites_per_link_indefinite,
    }
    Dir.mktmpdir do |dir|
      ClimateControl.modify(GROUP_CREATION_ICON_ROOT: dir, GROUP_CREATION_ICON_STORAGE: 'filesystem', S3_ENABLED: nil, SWIFT_ENABLED: nil) do
        example.run
      end
    end
  ensure
    Setting.group_creation_requests = previous[:requests]
    Setting.group_registration_invites_enabled = previous[:enabled]
    Setting.group_registration_invites_shared_quota = previous[:quota]
    Setting.group_registration_invites_shared_quota_unlimited = previous[:quota_unlimited]
    Setting.group_registration_invites_per_link_max_uses = previous[:max_uses]
    Setting.group_registration_invites_per_link_unlimited_uses = previous[:unlimited_uses]
    Setting.group_registration_invites_per_link_lifetime_seconds = previous[:lifetime]
    Setting.group_registration_invites_per_link_indefinite = previous[:indefinite]
  end

  let(:png) { File.binread(Rails.root.join('spec/fixtures/files/emojo.png')) }
  let(:owner) { user_with_role('Owner') }
  let(:admin_role) { user_with_role('Admin') }
  let(:moderator) { user_with_role('Moderator') }
  let(:requester) { Fabricate(:user, account: Fabricate(:account, username: 'requester')) }

  def defaults_fingerprint(body)
    Nokogiri::HTML(body).at_css('#form_group_registration_invite_defaults_fingerprint')&.[]('value')
  end

  def enable_requests!
    Setting.group_creation_requests = true
  end

  def sign_in_as(user)
    sign_in user, scope: :user
  end

  def submit_request(username: 'queuedgroup', requester_account: requester.account, **attrs)
    GroupCreationRequest.create!(
      {
        requester_account: requester_account,
        username: username,
        display_name: 'Queued Group',
        note: 'A requested group',
      }.merge(attrs)
    )
  end

  def stage_request(username: 'icongroup')
    key = GroupCreationIcons.generate_key
    GroupCreationIcons::Storage.resolve.write(key, StringIO.new(png), content_type: 'image/png')
    submit_request(
      username: username,
      icon_storage_key: key,
      icon_content_type: 'image/png',
      icon_byte_size: png.bytesize
    )
  end

  def approve_request(request, reviewer = owner)
    GroupCreationRequests::ApproveService.call(request: request, reviewer_account: reviewer.account)
  end

  def screen_paths(request, managed_group)
    [
      admin_group_creation_requests_path,
      admin_group_creation_request_path(request),
      admin_managed_groups_path,
      admin_managed_group_path(managed_group),
      edit_admin_group_registration_invite_defaults_path,
    ]
  end

  def protected_paths(request, managed_group)
    screen_paths(request, managed_group) + [icon_admin_group_creation_request_path(request)]
  end

  describe 'authorization' do
    let!(:request) { submit_request }
    let!(:managed_group) do
      enable_requests!
      approve_request(submit_request(username: 'ownedgroup')).group_account.managed_group
    end

    it 'refuses anonymous visitors, moderators, members, legacy admin flags, and the group owner' do
      protected_paths(request, managed_group).each do |path|
        get path
        expect(response).to have_http_status(:forbidden), path
      end

      [moderator, Fabricate(:user), Fabricate(:user, admin: true), requester].each do |user|
        sign_in_as user
        protected_paths(request, managed_group).each do |path|
          get path
          expect(response).to have_http_status(:forbidden), "#{user.id} #{path}"
        end
        post approve_admin_group_creation_request_path(request)
        expect(response).to have_http_status(:forbidden)
        post reject_admin_group_creation_request_path(request), params: { decision_note: 'no' }
        expect(response).to have_http_status(:forbidden)
        sign_out :user
      end

      expect(request.reload).to be_pending
      expect(Account.where(username: 'queuedgroup')).to be_empty
    end

    it 'lets an Owner and an Admin open the screens' do
      [owner, admin_role].each do |user|
        sign_in_as user
        screen_paths(request, managed_group).each do |path|
          get path
          expect(response).to have_http_status(:ok), "#{user.role.name} #{path}"
        end
        sign_out :user
      end
    end
  end

  describe 'review queue' do
    before { sign_in_as owner }

    it 'lists pending first, filters history, paginates, and avoids a query per requester' do
      enable_requests!
      submit_request(username: 'oldestpending')
      submit_request(username: 'olderpending')
      submit_request(username: 'newerpending')
      rejected = submit_request(username: 'rejectedname')
      rejected.record_rejection!(reviewer_account: owner.account, decision_note: 'not this one')
      approved = approve_request(submit_request(username: 'approvedname'))
      expect(approved.code).to eq :approved
      legacy = Fabricate(:account, username: 'legacygroup', actor_type: 'Group')
      Fabricate(:user, account: legacy)

      get admin_group_creation_requests_path
      expect(response.body).to include('newerpending', 'olderpending', 'oldestpending')
      expect(response.body).not_to include('rejectedname', 'approvedname', 'legacygroup')
      expect(response.body.index('newerpending')).to be < response.body.index('olderpending')

      get admin_group_creation_requests_path, params: { state: 'all' }
      expect(response.body.index('newerpending')).to be < response.body.index('approvedname')
      expect(response.body).not_to include('legacygroup')

      get admin_group_creation_requests_path, params: { state: 'rejected' }
      expect(response.body).to include('rejectedname')
      expect(response.body).not_to include('not this one')

      get admin_group_creation_requests_path, params: { state: 'nope' }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('newerpending')
      expect(response.body).not_to include('rejectedname')

      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        sql = payload[:sql].to_s
        queries << sql unless payload[:name] == 'SCHEMA' || sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        get admin_group_creation_requests_path, params: { state: 'all' }
      end
      account_selects = queries.select { |sql| sql.include?('SELECT') && sql.include?('"accounts"') }
      expect(account_selects.size).to be <= 4, account_selects.join("\n")

      stub_const('Admin::GroupAdministrationConcern::PAGE_SIZE', 2)
      get admin_group_creation_requests_path, params: { state: 'pending', page: 2 }
      expect(response.body).to include('oldestpending')
      expect(response.body).not_to include('newerpending')
    end

    it 'shows Japanese copy for a Japanese administrator' do
      owner.update!(locale: 'ja')
      submit_request
      get admin_group_creation_requests_path
      expect(response.body).to include(I18n.t('admin.group_creation_requests.title', locale: :ja))
      expect(response.body).to include(I18n.t('admin.group_creation_requests.states.pending', locale: :ja))
    end
  end

  describe 'decisions' do
    before { sign_in_as owner }

    it 'refuses approval while the feature is off and does not turn the feature on' do
      request = submit_request
      expect(Setting.group_creation_requests).to eq false

      expect do
        post approve_admin_group_creation_request_path(request)
      end.not_to change(Account, :count)

      expect(response).to redirect_to(admin_group_creation_request_path(request))
      follow_redirect!
      expect(response.body).to include(I18n.t('admin.group_creation_requests.errors.feature_disabled'))
      expect(request.reload).to be_pending
      expect(Setting.group_creation_requests).to eq false
      expect(Admin::ActionLog.where(target: request, action: 'fail').last.recorded_changes).to eq('code' => 'feature_disabled')

      allow(GroupAdministration::Audit).to receive(:record!).and_raise(GroupAdministration::Audit::Error)
      post approve_admin_group_creation_request_path(request)
      follow_redirect!
      expect(response.body).to include(I18n.t('admin.group_administration.audit_failed'))
      expect(response.body).not_to include(I18n.t('admin.group_creation_requests.results.approved'))
      expect(request.reload).to be_pending
    end

    it 'approves through the service, audits it, and does not follow or create a login' do
      enable_requests!
      request = submit_request
      users = User.count

      expect do
        post approve_admin_group_creation_request_path(request)
      end.to change(Account, :count).by(1)

      request.reload
      group = request.group_account
      expect(group.user).to be_nil
      expect(group.group?).to be true
      expect(Follow.where(account: requester.account, target_account: group)).to be_empty
      expect(User.count).to eq users
      expect(response).to redirect_to(admin_group_creation_request_path(request))
      follow_redirect!
      expect(response.body).to include(I18n.t('admin.group_creation_requests.results.approved'))
      expect(response.headers['Cache-Control']).to eq 'private, no-store'
      expect(Admin::ActionLog.where(target: request, action: 'approve')).to be_empty
      expect(request.decision).to be_approved
      expect(request.decision.reviewer_account).to eq owner.account

      post approve_admin_group_creation_request_path(request)
      follow_redirect!
      expect(response.body).to include(I18n.t('admin.group_creation_requests.errors.not_pending'))
      expect(Account.where(username: 'queuedgroup').count).to eq 1
    end

    it 'requires a rejection reason and keeps a blank rejection pending' do
      enable_requests!
      request = submit_request

      post reject_admin_group_creation_request_path(request), params: { decision_note: '   ' }
      follow_redirect!
      expect(response.body).to include(I18n.t('admin.group_creation_requests.errors.decision_note_blank'))
      expect(request.reload).to be_pending

      post reject_admin_group_creation_request_path(request), params: { decision_note: 'Name is unclear' }
      follow_redirect!
      expect(response.body).to include('Name is unclear')
      expect(request.reload).to be_rejected
      expect(Account.where(username: 'queuedgroup')).to be_empty
      expect(response.headers['Cache-Control']).to eq 'private, no-store'
    end

    it 'keeps pending when the username is taken, the requester is unusable, the icon is missing, or the request was cancelled' do
      enable_requests!
      taken = submit_request(username: 'takenname')
      Fabricate(:account, username: 'takenname')
      post approve_admin_group_creation_request_path(taken)
      follow_redirect!
      expect(response.body).to include(I18n.t('admin.group_creation_requests.errors.username_taken'))
      expect(taken.reload).to be_pending

      invalid = submit_request(username: 'invalidperson')
      requester.account.update!(suspended_at: Time.now.utc)
      post approve_admin_group_creation_request_path(invalid)
      follow_redirect!
      expect(response.body).to include(I18n.t('admin.group_creation_requests.errors.invalid_requester'))
      expect(invalid.reload).to be_pending
      requester.account.update!(suspended_at: nil)

      missing = stage_request(username: 'missingicon')
      GroupCreationIcons::Storage.resolve.delete(missing.icon_storage_key)
      post approve_admin_group_creation_request_path(missing)
      follow_redirect!
      expect(response.body).to include(I18n.t('admin.group_creation_requests.errors.icon_missing'))
      expect(missing.reload).to be_pending

      cancelled = submit_request(username: 'cancelledname')
      cancelled.record_cancellation!
      post approve_admin_group_creation_request_path(cancelled)
      follow_redirect!
      expect(response.body).to include(I18n.t('admin.group_creation_requests.errors.not_pending'))
      expect(cancelled.reload).to be_cancelled
      expect(Account.where(username: %w(takenname invalidperson missingicon cancelledname), actor_type: 'Group')).to be_empty
    end

    it 'does not reject or approve when the CSRF token is missing' do
      enable_requests!
      request = submit_request
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true

      post reject_admin_group_creation_request_path(request), params: { decision_note: 'secret-review-note' }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(request.reload).to be_pending
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end
  end

  describe 'private icon preview' do
    let!(:request) { stage_request }

    it 'streams the bytes only to an administrator and hides the storage key' do
      sign_in_as moderator
      get icon_admin_group_creation_request_path(request)
      expect(response).to have_http_status(:forbidden)
      expect(response.headers['Cache-Control']).to eq 'private, no-store'
      expect(response.body).not_to include(png)
      expect(response.body).not_to include(request.icon_storage_key)

      sign_out moderator
      sign_in_as owner
      get admin_group_creation_request_path(request)
      expect(response.body).to include(icon_admin_group_creation_request_path(request))
      expect(response.body).not_to include(request.icon_storage_key)
      expect(response.headers['Cache-Control']).to eq 'private, no-store'

      get icon_admin_group_creation_request_path(request)
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq png
      expect(response.headers['Cache-Control']).to eq 'private, no-store'
      expect(response.headers['X-Content-Type-Options']).to eq 'nosniff'
      expect(response.media_type).to eq 'image/png'

      secret = 'secret-review-note-zz'
      request.record_rejection!(reviewer_account: owner.account, decision_note: secret)
      get "/api/v1/accounts/#{requester.account.id}"
      expect(response.body).not_to include(secret)
      get "/users/#{requester.account.username}", headers: { 'Accept' => 'application/activity+json' }
      expect(response.body).not_to include(secret)
    end

    it 'filters the review note from parameter logs' do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      expect(filter.filter(decision_note: 'secret-review-note')[:decision_note]).to eq '[FILTERED]'
    end

    it 'does not read an oversized icon and keeps failure responses uncached' do
      sign_in_as owner
      storage = GroupCreationIcons::Storage.resolve
      allow(storage).to receive(:byte_size).and_return(GroupCreationIcons::MAX_BYTES)
      allow(storage).to receive(:read)
      allow(GroupCreationIcons::Storage).to receive(:resolve).and_return(storage)

      get icon_admin_group_creation_request_path(request)
      expect(response).to have_http_status(:not_found)
      expect(response.headers['Cache-Control']).to eq 'private, no-store'
      expect(storage).not_to have_received(:read)

      allow(storage).to receive(:byte_size).and_raise(Errno::ECONNREFUSED)
      get icon_admin_group_creation_request_path(request)
      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers['Cache-Control']).to eq 'private, no-store'
      expect(response.body).not_to include('ECONNREFUSED')
      expect(response.body).not_to include(request.icon_storage_key)
    end
  end

  describe 'registered groups and invite policy' do
    before do
      enable_requests!
      sign_in_as owner
    end

    it 'separates the site defaults from an existing group and refuses bad values' do
      first = approve_request(submit_request(username: 'firstgroup'))
      policy = first.group_account.group_registration_invite_policy
      expect(policy.shared_registration_quota).to eq 0
      legacy = Fabricate(:account, username: 'unmanaged', actor_type: 'Group')

      get admin_managed_groups_path
      expect(response.body).to include('firstgroup')
      expect(response.body).not_to include('unmanaged')
      expect(legacy.managed_group).to be_nil

      get edit_admin_group_registration_invite_defaults_path
      fingerprint = defaults_fingerprint(response.body)
      expect(fingerprint).to be_present
      expect(response.body).to include(I18n.t('admin.group_administration.no'))
      expect(response.body).not_to include('translation_missing')

      Setting.group_creation_requests = false
      patch admin_group_registration_invite_defaults_path, params: {
        group_creation_requests: true,
        form_group_registration_invite_defaults: {
          fingerprint: fingerprint,
          issuance_enabled: '0',
          shared_quota_unlimited: '0',
          shared_registration_quota: '4',
          per_link_unlimited_uses: '0',
          per_link_max_uses: '2',
          per_link_indefinite: '0',
          per_link_lifetime_seconds: '3600',
        },
      }
      expect(response).to redirect_to(edit_admin_group_registration_invite_defaults_path)
      expect(Setting.group_creation_requests).to eq false
      expect(Setting.group_registration_invites_shared_quota).to eq 4
      Setting.group_creation_requests = true
      expect(policy.reload.shared_registration_quota).to eq 0
      expect(policy.per_link_max_uses).to eq 1

      second = approve_request(submit_request(username: 'secondgroup'))
      expect(second.group_account.group_registration_invite_policy.shared_registration_quota).to eq 4
      expect(second.group_account.group_registration_invite_policy.per_link_lifetime_seconds).to eq 3600
      expect(policy.reload.shared_registration_quota).to eq 0

      patch admin_managed_group_registration_invite_policy_path(first.group_account.managed_group), params: {
        group_registration_invite_policy: {
          lock_version: policy.lock_version,
          issuance_enabled: '1',
          shared_quota_unlimited: '1',
          shared_registration_quota: '5',
          per_link_unlimited_uses: '0',
          per_link_max_uses: '0',
          per_link_indefinite: '0',
          per_link_lifetime_seconds: '10',
        },
      }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('admin.managed_groups.policy_errors.invalid'))
      expect(policy.reload.issuance_enabled).to eq false
      expect(policy.shared_quota_unlimited).to eq false
      expect(Setting.group_registration_invites_shared_quota).to eq 4

      stale = policy.lock_version
      policy.update!(shared_registration_quota: 3)
      patch admin_managed_group_registration_invite_policy_path(first.group_account.managed_group), params: {
        group_registration_invite_policy: {
          lock_version: stale,
          issuance_enabled: '0',
          shared_quota_unlimited: '0',
          shared_registration_quota: '9',
          per_link_unlimited_uses: '0',
          per_link_max_uses: '1',
          per_link_indefinite: '0',
          per_link_lifetime_seconds: '10',
        },
      }
      expect(response.body).to include(I18n.t('admin.managed_groups.policy_errors.conflict'))
      expect(policy.reload.shared_registration_quota).to eq 3

      patch admin_managed_group_registration_invite_policy_path(first.group_account.managed_group), params: {
        group_registration_invite_policy: {
          lock_version: policy.lock_version,
          issuance_enabled: '1',
          shared_quota_unlimited: '0',
          shared_registration_quota: '6',
          per_link_unlimited_uses: '0',
          per_link_max_uses: '3',
          per_link_indefinite: '0',
          per_link_lifetime_seconds: '90',
        },
      }
      expect(response).to redirect_to(admin_managed_group_path(first.group_account.managed_group))
      expect(policy.reload.shared_registration_quota).to eq 6
      expect(policy.issuance_enabled).to eq true
      expect(second.group_account.group_registration_invite_policy.reload.shared_registration_quota).to eq 4
      log = Admin::ActionLog.where(target: policy, action: 'update_invite_policy').last
      expect(log.recorded_changes['before']['shared_registration_quota']).to eq 3
      expect(log.recorded_changes['after']['shared_registration_quota']).to eq 6
      expect(log.recorded_changes['after']).not_to have_key('decision_note')
    end

    it 'rejects an unlimited shared quota that is not zero and a stale defaults form' do
      get edit_admin_group_registration_invite_defaults_path
      fingerprint = defaults_fingerprint(response.body)
      expect(fingerprint).to be_present

      patch admin_group_registration_invite_defaults_path, params: {
        form_group_registration_invite_defaults: {
          fingerprint: fingerprint,
          issuance_enabled: '1',
          shared_quota_unlimited: '1',
          shared_registration_quota: '5',
          per_link_unlimited_uses: '0',
          per_link_max_uses: '1',
          per_link_indefinite: '0',
          per_link_lifetime_seconds: '60',
        },
      }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('admin.group_registration_invite_defaults.errors.shared_quota_unlimited_mismatch'))
      expect(Setting.group_registration_invites_shared_quota_unlimited).to eq false

      Setting.group_registration_invites_shared_quota = 2
      patch admin_group_registration_invite_defaults_path, params: {
        form_group_registration_invite_defaults: {
          fingerprint: fingerprint,
          issuance_enabled: '0',
          shared_quota_unlimited: '0',
          shared_registration_quota: '8',
          per_link_unlimited_uses: '0',
          per_link_max_uses: '1',
          per_link_indefinite: '0',
          per_link_lifetime_seconds: '60',
        },
      }
      expect(response.body).to include(I18n.t('admin.group_registration_invite_defaults.errors.conflict'))
      expect(Setting.group_registration_invites_shared_quota).to eq 2
    end

    it 'does not save defaults when the administration log cannot be written' do
      first = approve_request(submit_request(username: 'auditedgroup'))
      policy = first.group_account.group_registration_invite_policy
      get edit_admin_group_registration_invite_defaults_path
      fingerprint = defaults_fingerprint(response.body)
      allow(GroupAdministration::Audit).to receive(:record!).and_raise(GroupAdministration::Audit::Error)

      patch admin_group_registration_invite_defaults_path, params: {
        form_group_registration_invite_defaults: {
          fingerprint: fingerprint,
          issuance_enabled: '0',
          shared_quota_unlimited: '0',
          shared_registration_quota: '7',
          per_link_unlimited_uses: '0',
          per_link_max_uses: '1',
          per_link_indefinite: '0',
          per_link_lifetime_seconds: '60',
        },
      }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('admin.group_administration.audit_failed'))
      expect(response.body).not_to include(I18n.t('admin.group_registration_invite_defaults.saved'))
      expect(Setting.group_registration_invites_shared_quota).to eq 0
      expect(policy.reload.shared_registration_quota).to eq 0
    end

    it 'rolls back a group policy change when the administration log cannot be written' do
      approved = approve_request(submit_request(username: 'policyaudit'))
      policy = approved.group_account.group_registration_invite_policy
      allow(GroupAdministration::Audit).to receive(:record!).and_raise(GroupAdministration::Audit::Error)

      patch admin_managed_group_registration_invite_policy_path(approved.group_account.managed_group), params: {
        group_registration_invite_policy: {
          lock_version: policy.lock_version,
          issuance_enabled: '1',
          shared_quota_unlimited: '0',
          shared_registration_quota: '4',
          per_link_unlimited_uses: '0',
          per_link_max_uses: '2',
          per_link_indefinite: '0',
          per_link_lifetime_seconds: '30',
        },
      }

      expect(response.body).to include(I18n.t('admin.managed_groups.policy_errors.audit_failed'))
      expect(policy.reload.shared_registration_quota).to eq 0
      expect(policy.issuance_enabled).to eq false
    end
  end

  describe 'icon retry' do
    before do
      enable_requests!
      sign_in_as owner
    end

    it 'resets an exhausted copy and queues the existing worker' do
      request = stage_request(username: 'retrygroup')
      allow(GroupCreationIcons::HandoffWorker).to receive(:perform_async)
      post approve_admin_group_creation_request_path(request)
      request.reload
      request.update!(icon_handoff_attempts: GroupCreationIcons::Copy::MAX_ATTEMPTS, icon_handoff_error: 'copy_failed', icon_handoff_failed_at: Time.current)

      expect(GroupCreationIcons::HandoffWorker).to receive(:perform_async).with(request.id)
      expect do
        post retry_icon_admin_group_creation_request_path(request)
      end.not_to change(Account, :count)

      expect(request.reload.icon_handoff_attempts).to eq 0
      expect(request.icon_handoff_error).to be_nil
      expect(request).to be_approved
      expect(Admin::ActionLog.where(target: request, action: 'retry_icon').last.recorded_changes).to eq('code' => 'resumed')
    end
  end
end
