# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ActionReviewsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:admin) { Fabricate(:user, admin: true) }
  let(:user) { Fabricate(:user, password: '12345678') }

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  def hold
    Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
      value: { 'account_migration' => 'always' }
    )
    Rails.cache.clear
    target = Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(user.account)])
    AccountMigration::CreateService.new.call(
      account: user.account,
      user: user,
      attributes: { acct: target.acct, current_password: '12345678' }
    )
  end

  before do
    stub_webpacker_manifest
    sign_in admin, scope: :user
    allow(AccountMigration::ActionReviewExecutionWorker).to receive(:perform_async)
  end

  after do
    Setting.where(var: 'action_review_policies').delete_all
    Rails.cache.clear
  end

  it 'shows factual migration metrics, current observation, and approve/stop controls' do
    created = hold
    evidence = created.request.evidence

    get :show, params: { id: created.request }

    expect(response.body).to include(I18n.t('admin.action_reviews.account_migration.title'))
    expect(response.body).to include(I18n.t('admin.action_reviews.account_migration.request_snapshot'))
    expect(response.body).to include(I18n.t('admin.action_reviews.account_migration.current_observation'))
    expect(response.body).to include(I18n.t('admin.action_reviews.account_migration.caveat'))
    expect(response.body).to include(I18n.t('admin.action_reviews.account_migration.metrics.returned_follows_after_outgoing'))
    expect(response.body).to include(I18n.t('admin.action_reviews.approve_migration'))
    expect(response.body).to include(I18n.t('admin.action_reviews.migration_stop_confirm'))
    expect(response.body).to include(admin_account_path(user.account))
    expect(response.body).to include(admin_account_path(created.migration.target_account))
    expect(response.body).to include(evidence['metrics']['generated_at'])
    expect(response.body).to include('time')
    expect(response.body).not_to include('12345678')
    expect(response.body).not_to include('malicious')
    expect(response.body).not_to include('sockpuppet')
  end

  it 'approves into the execution queue without a moderation action' do
    created = hold

    expect { post :approve, params: { id: created.request } }.not_to change(ModerationAction, :count)

    expect(response).to redirect_to(admin_action_review_path(created.request))
    expect(flash[:notice]).to eq I18n.t('admin.action_reviews.migration_approved_msg')
    expect(created.request.reload.approved_state?).to be true
    expect(user.account.reload.moved_to_account_id).to be_nil
  end

  it 'hides controls after the migration is stopped' do
    created = hold
    evidence = created.request.evidence.deep_dup
    ActionReview::DecisionService.new.call(
      request: created.request,
      decision: 'reject',
      reviewer_account: admin.account,
      decision_note: nil
    )

    get :show, params: { id: created.request }

    expect(response.body).to include(I18n.t('admin.action_reviews.account_migration.stopped'))
    expect(response.body).not_to include(I18n.t('admin.action_reviews.approve_migration'))
    expect(response.body).not_to include(I18n.t('admin.action_reviews.account_migration.current_observation'))
    expect(created.request.reload.evidence).to eq evidence
  end

  it 'warns when the cached target no longer references the source' do
    created = hold
    created.migration.target_account.update!(also_known_as: [])

    get :show, params: { id: created.request }

    expect(response.body).to include(I18n.t('admin.action_reviews.inconsistent_migration'))
    expect(response.body).not_to include(I18n.t('admin.action_reviews.approve_migration'))
  end
end
