# frozen_string_literal: true

require 'rails_helper'

describe Settings::MigrationsController do # rubocop:disable Metrics/BlockLength
  render_views

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  before { stub_webpacker_manifest }

  shared_examples 'authenticate user' do
    it 'redirects to sign_in page' do
      is_expected.to redirect_to new_user_session_path
    end
  end

  describe 'GET #show' do
    context 'when user is not sign in' do
      subject { get :show }

      it_behaves_like 'authenticate user'
    end

    context 'when user is sign in' do
      subject { get :show }

      let(:user) { Fabricate(:user, account: account) }
      let(:account) { Fabricate(:account, moved_to_account: moved_to_account) }

      before { sign_in user, scope: :user }

      context 'when user does not have moved to account' do
        let(:moved_to_account) { nil }

        it 'renders show page' do
          is_expected.to have_http_status 200
          is_expected.to render_template :show
        end
      end

      context 'when user has a moved to account' do
        let(:moved_to_account) { Fabricate(:account) }

        it 'renders show page' do
          is_expected.to have_http_status 200
          is_expected.to render_template :show
        end
      end
    end
  end

  describe 'POST #create' do
    context 'when user is not sign in' do
      subject { post :create }

      it_behaves_like 'authenticate user'
    end

    context 'when user is signed in' do
      subject { post :create, params: { account_migration: { acct: acct, current_password: '12345678' } } }

      let(:user) { Fabricate(:user, password: '12345678') }

      before { sign_in user, scope: :user }

      context 'when migration account is changed' do
        let(:acct) { Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(user.account)]) }

        it 'updates moved to account' do
          is_expected.to redirect_to settings_migration_path
          expect(user.account.reload.moved_to_account_id).to eq acct.id
        end
      end

      context 'when acct is the current account' do
        let(:acct) { user.account }

        it 'renders show' do
          is_expected.to render_template :show
        end

        it 'does not update the moved account' do
          expect(user.account.reload.moved_to_account_id).to be_nil
        end
      end

      context 'when target account does not reference the account being moved from' do
        let(:acct) { Fabricate(:account, also_known_as: []) }

        it 'renders show' do
          is_expected.to render_template :show
        end

        it 'does not update the moved account' do
          expect(user.account.reload.moved_to_account_id).to be_nil
        end
      end

      context 'when a recent migration already exists ' do
        let(:acct) { Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(user.account)]) }

        before do
          moved_to = Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(user.account)])
          user.account.migrations.create!(acct: moved_to.acct)
        end

        it 'renders show' do
          is_expected.to render_template :show
        end

        it 'does not update the moved account' do
          expect(user.account.reload.moved_to_account_id).to be_nil
        end
      end
    end
  end

  describe 'POST #create with action review' do
    let(:user) { Fabricate(:user, password: '12345678') }
    let(:acct) { Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(user.account)]) }

    before { sign_in user, scope: :user }

    after do
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end

    def store_policy(mode)
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'account_migration' => mode }
      )
      Rails.cache.clear
    end

    it 'keeps the ordinary moved notice when policy is off' do
      store_policy('off')

      post :create, params: { account_migration: { acct: acct.acct, current_password: '12345678' } }

      expect(response).to redirect_to settings_migration_path
      expect(flash[:notice]).to eq I18n.t('migrations.moved_msg', acct: acct.acct)
      expect(ActionReviewRequest.count).to eq 0
    end

    it 'waits for approval and says that no move has started' do
      store_policy('always')

      post :create, params: { account_migration: { acct: acct.acct, current_password: '12345678' } }

      expect(response).to redirect_to settings_migration_path
      expect(flash[:notice]).to eq I18n.t('migrations.pending_review')
      expect(user.account.reload.moved_to_account_id).to be_nil
      expect(ActionReviewRequest.last.pending_state?).to be true
    end

    it 'still rejects a second submission while a review is pending' do
      store_policy('always')
      post :create, params: { account_migration: { acct: acct.acct, current_password: '12345678' } }
      other = Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(user.account)])

      post :create, params: { account_migration: { acct: other.acct, current_password: '12345678' } }

      expect(response).to render_template :show
      expect(AccountMigration.where(account_id: user.account.id).count).to eq 1
      expect(user.account.reload.moved_to_account_id).to be_nil
    end
  end

  describe 'GET #show review rows' do
    let(:user) { Fabricate(:user, password: '12345678') }

    before { sign_in user, scope: :user }

    def migration_with_review(state:, executed_at: nil, note: nil)
      user.account.migrations.update_all(created_at: 31.days.ago)
      target = Fabricate(:account, also_known_as: [ActivityPub::TagManager.instance.uri_for(user.account)])
      migration = user.account.migrations.create!(acct: target.acct)
      migration.update_column(:action_review_executed_at, executed_at) if executed_at
      ActionReviewRequest.create!(
        operation_type: 'account_migration',
        state: state,
        actor_account: user.account,
        resource: migration,
        trigger: 'policy',
        signal_level: 'none',
        policy_mode: 'always',
        policy_version: 'action-review-policy-v1',
        reason_codes: ['policy_always'],
        evidence: { 'schema_version' => 1 },
        requested_at: Time.now.utc,
        decision_note: note
      )
      migration
    end

    it 'shows waiting, processing, moved, and stopped without moderator notes' do
      pending = migration_with_review(state: :pending)
      pending.update_column(:created_at, 2.days.ago)
      processing = migration_with_review(state: :approved)
      processing.update_column(:created_at, 3.days.ago)
      moved = migration_with_review(state: :approved, executed_at: Time.now.utc)
      moved.update_column(:created_at, 4.days.ago)
      stopped = migration_with_review(state: :rejected, note: 'secret-moderator-note')
      stopped.update_column(:created_at, 5.days.ago)
      cancelled = migration_with_review(state: :cancelled, note: 'secret-cancelled-note')
      cancelled.update_column(:created_at, 40.days.ago)

      get :show

      expect(response.body).to include(I18n.t('migrations.review.waiting'))
      expect(response.body).to include(I18n.t('migrations.review.processing'))
      expect(response.body).to include(I18n.t('migrations.review.moved'))
      expect(response.body).to include(I18n.t('migrations.review.stopped'))
      expect(response.body).not_to include('secret-moderator-note')
      expect(response.body).not_to include('secret-cancelled-note')
    end

    it 'lets the owner submit again after a rejected or cancelled review' do
      rejected = migration_with_review(state: :rejected)
      rejected.update_column(:created_at, 1.day.ago)

      get :show

      expect(response.body).to include(I18n.t('migrations.proceed_with_move'))
      expect(response.body).not_to include(I18n.t('migrations.errors.on_cooldown'))
    end
  end
end
