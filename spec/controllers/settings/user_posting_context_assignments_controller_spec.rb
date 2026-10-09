# frozen_string_literal: true

require 'rails_helper'

describe Settings::UserPostingContextAssignmentsController do
  render_views

  let(:owner) { user_with_role('Owner') }

  def style_for(user, **attributes)
    user.user_posting_contexts.create!({ name: 'Notes', icon: '📝' }.merge(attributes))
  end

  def group_account(username)
    Fabricate(:account, username: username, actor_type: 'Group')
  end

  def sql_statements
    statements = []
    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      sql = payload[:sql].to_s
      next if payload[:cached] || payload[:name] == 'SCHEMA'
      next if sql.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      statements << sql
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    statements
  end

  describe 'access' do
    it 'redirects anonymous visitors and forbids a non-administrator' do
      get :index
      expect(response).to redirect_to(new_user_session_path)

      sign_in Fabricate(:user), scope: :user
      get :index
      expect(response).to have_http_status(:forbidden)

      sign_in user_with_role('Admin'), scope: :user
      get :index
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'managing the signed-in user defaults' do
    before { sign_in owner, scope: :user }

    let(:group) { group_account('localsquad') }
    let(:other_group) { group_account('othersquad') }
    let(:list) { Fabricate(:list, account: owner.account, title: 'Reading <list>') }
    let(:common) { style_for(owner, name: 'Common <style>') }
    let(:tagged) { style_for(owner, name: 'Books', icon: '📚', target_kind: 'hashtag', target_hashtag: 'Foo') }

    it 'lists this user places, keeps none, and does not show another user' do
      other = Fabricate(:user)
      foreign_list = Fabricate(:list, account: other.account, title: 'Secret shelf')
      foreign_style = style_for(other, name: 'Foreign style')
      UserPostingContextAssignment.assign!(user: other, surface_kind: 'list', surface_key: foreign_list.id.to_s, style: foreign_style)
      UserPostingContextAssignment.assign!(user: owner, surface_kind: 'group', surface_key: group.id.to_s, style: common)
      UserPostingContextAssignment.assign!(user: owner, surface_kind: 'hashtag', surface_key: '#Foo', style: tagged)
      UserPostingContextAssignment.assign!(user: owner, surface_kind: 'list', surface_key: list.id.to_s, style: nil)
      unavailable = UserPostingContextAssignment.assign!(user: owner, surface_kind: 'group', surface_key: other_group.id.to_s, style: common)
      common.update!(target_kind: 'group', target_account: group)
      unavailable.reload

      expect(PostingContext::DiscoveryService).not_to receive(:new)
      expect(ResolveAccountService).not_to receive(:new)
      expect(ActivityPub::FetchRemoteAccountService).not_to receive(:new)
      expect(UserPostingContext::Preview).not_to receive(:build)

      get :index

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_posting_context_assignments.kinds.group'))
      expect(response.body).to include(I18n.t('user_posting_context_assignments.kinds.hashtag'))
      expect(response.body).to include(I18n.t('user_posting_context_assignments.kinds.list'))
      expect(response.body).to include(group.acct)
      expect(response.body).to include('#foo')
      expect(response.body).to include('Reading &lt;list&gt;')
      expect(response.body).not_to include('Reading <list>')
      expect(response.body).to include('Common &lt;style&gt;')
      expect(response.body).not_to include('Common <style>')
      expect(response.body).to include('📚')
      expect(response.body).to include(I18n.t('user_posting_context_assignments.availability.none'))
      expect(response.body).to include(I18n.t('user_posting_context_assignments.availability.unavailable'))
      expect(response.body).to include(I18n.t('user_posting_context_assignments.return_to_automatic_hint'))
      expect(response.body).to include('name="lock_version"')
      expect(response.body).not_to include('Secret shelf')
      expect(response.body).not_to include('Foreign style')
      expect(unavailable.availability_status).to eq('unavailable')

      get :index, params: { user_posting_context_id: common.id }

      statuses = Nokogiri::HTML(response.body).css('.user-posting-assignment__status').map { |node| node.text.strip }
      expect(response.body).to include(group.acct)
      expect(statuses).to include(I18n.t('user_posting_context_assignments.availability.unavailable'))
      expect(statuses).not_to include(I18n.t('user_posting_context_assignments.availability.none'))
      expect(response.body).not_to include('#foo')

      get :index, params: { user_posting_context_id: foreign_style.id }
      expect(response).to have_http_status(:not_found)
    end

    it 'returns a place to unset, stores explicit none, and rejects another user or a stale lock' do
      chosen = style_for(owner, name: 'Chosen')
      replacement = style_for(owner, name: 'Replacement')
      record = UserPostingContextAssignment.assign!(user: owner, surface_kind: 'group', surface_key: group.id.to_s, style: chosen)
      none_row = UserPostingContextAssignment.assign!(user: owner, surface_kind: 'hashtag', surface_key: 'kept', style: nil)
      other = Fabricate(:user)
      foreign = UserPostingContextAssignment.assign!(user: other, surface_kind: 'group', surface_key: group.id.to_s, style: nil)

      post :release, params: { id: record.id, lock_version: record.lock_version }
      expect(response).to redirect_to(settings_user_posting_context_assignments_path)
      expect(flash[:notice]).to eq(I18n.t('user_posting_context_assignments.released'))
      expect(UserPostingContextAssignment.exists?(record.id)).to be false

      post :release, params: { id: record.id, lock_version: record.lock_version }
      expect(response).to have_http_status(:not_found)

      post :decline, params: { id: none_row.id, lock_version: none_row.lock_version }
      expect(response).to redirect_to(settings_user_posting_context_assignments_path)
      expect(none_row.reload.user_posting_context_id).to be_nil
      expect(none_row.availability_status).to eq('none')

      kept = UserPostingContextAssignment.assign!(user: owner, surface_kind: 'group', surface_key: other_group.id.to_s, style: chosen)
      stale = kept.lock_version
      UserPostingContextAssignment.assign!(user: owner, surface_kind: 'group', surface_key: other_group.id.to_s, style: replacement)

      post :release, params: { id: kept.id, lock_version: stale }
      expect(response).to have_http_status(:conflict)
      expect(response.body).to include(I18n.t('user_posting_context_assignments.stale'))
      expect(response.body).to include('Replacement')
      expect(kept.reload.user_posting_context_id).to eq(replacement.id)

      post :release, params: { id: kept.id }
      expect(response).to have_http_status(:conflict)
      expect(kept.reload.user_posting_context_id).to eq(replacement.id)

      post :release, params: { id: foreign.id, lock_version: foreign.lock_version }
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload).to be_present

      post :decline, params: { id: kept.id, lock_version: kept.lock_version }
      expect(response).to redirect_to(settings_user_posting_context_assignments_path)
      expect(kept.reload.user_posting_context_id).to be_nil
      expect(kept.availability_status).to eq('none')
      expect(UserPostingContextAssignment.where(user: owner, surface_kind: 'group', surface_key: other_group.id.to_s).count).to eq(1)
    end

    it 'releases a deleted list and a group id that is no longer present' do
      UserPostingContextAssignment.assign!(user: owner, surface_kind: 'list', surface_key: list.id.to_s, style: common)
      List.where(id: list.id).delete_all
      missing_group = owner.user_posting_context_assignments.new(surface_kind: 'group', surface_key: '424242', user_posting_context: common)
      missing_group.save!(validate: false)

      expect(PostingContext::DiscoveryService).not_to receive(:new)
      expect(ResolveAccountService).not_to receive(:new)

      get :index

      expect(response.body).to include(I18n.t('user_posting_context_assignments.missing_list', id: list.id))
      expect(response.body).to include(I18n.t('user_posting_context_assignments.missing_group', id: '424242'))
      expect(response.body).to include(I18n.t('user_posting_context_assignments.place_unavailable'))
      expect(response.body).not_to include('Reading &lt;list&gt;')

      listed = owner.user_posting_context_assignments.find_by!(surface_kind: 'list', surface_key: list.id.to_s)
      post :release, params: { id: listed.id, lock_version: listed.lock_version }
      expect(response).to redirect_to(settings_user_posting_context_assignments_path)
      expect(UserPostingContextAssignment.exists?(listed.id)).to be false

      post :release, params: { id: missing_group.id, lock_version: missing_group.lock_version }
      expect(response).to redirect_to(settings_user_posting_context_assignments_path)
      expect(owner.user_posting_context_assignments.reload).to be_empty
    end

    it 'does not add a query per assignment' do
      style_for(owner, name: 'Idle')
      2.times do |index|
        UserPostingContextAssignment.assign!(
          user: owner,
          surface_kind: 'hashtag',
          surface_key: "quiet#{index}",
          style: common
        )
      end
      get :index
      small = sql_statements { get :index }.size

      12.times do |index|
        UserPostingContextAssignment.assign!(
          user: owner,
          surface_kind: 'hashtag',
          surface_key: "more#{index}",
          style: common
        )
      end
      large = sql_statements { get :index }.size

      expect(large).to eq(small)
    end

    it 'pages a long list' do
      21.times do |index|
        UserPostingContextAssignment.assign!(
          user: owner,
          surface_kind: 'hashtag',
          surface_key: format('page%02d', index),
          style: common
        )
      end

      get :index
      expect(response.body).to include('#page00')
      expect(response.body).not_to include('#page20')

      get :index, params: { page: 2 }
      expect(response.body).to include('#page20')
      expect(response.body).not_to include('#page00')
    end
  end
end
