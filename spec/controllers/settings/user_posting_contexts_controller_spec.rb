# frozen_string_literal: true

require 'rails_helper'

describe Settings::UserPostingContextsController do
  render_views

  let(:owner) { user_with_role('Owner') }
  let(:group) { Fabricate(:account, username: 'localsquad', actor_type: 'Group') }

  def style_params(extra = {})
    {
      name: 'Field notes',
      icon: '📝',
      purpose: 'Remember the local group',
      target_kind: 'none',
      visibility_choice: 'inherit',
      language_choice: 'inherit',
      sensitive_choice: 'inherit',
      spoiler_choice: 'inherit',
      hashtags_text: '',
    }.merge(extra)
  end

  describe 'access' do
    it 'redirects anonymous visitors to sign in' do
      get :index
      expect(response).to redirect_to(new_user_session_path)
    end

    it 'forbids a regular user and an admin role without the administrator flag' do
      sign_in Fabricate(:user), scope: :user
      get :index
      expect(response).to have_http_status(:forbidden)

      sign_in user_with_role('Admin'), scope: :user
      get :index
      expect(response).to have_http_status(:forbidden)
    end

    it 'shows the navigation entry only to an administrator' do
      sign_in owner, scope: :user
      get :index
      expect(response.body).to include(I18n.t('settings.user_posting_contexts'))
      expect(response.body).to include(I18n.t('user_posting_contexts.description'))
      expect(response.body).to include(I18n.t('user_posting_contexts.empty'))
    end
  end

  describe 'CRUD' do
    before { sign_in owner, scope: :user }

    it 'creates, edits, duplicates, and deletes only the signed-in user styles' do
      other = Fabricate(:user)
      foreign = other.user_posting_contexts.create!(name: 'Foreign', defaults: { 'visibility' => 'public' }, managed: { 'hashtags' => [] })

      expect do
        post :create, params: { user_posting_context: style_params(name: 'Field notes', visibility_choice: 'explicit', visibility_value: 'private', spoiler_choice: 'disabled', language_choice: 'auto', hashtags_text: '#Ruby・') }
      end.to change { owner.user_posting_contexts.count }.by(1)

      record = owner.user_posting_contexts.ordered.last
      expect(record.defaults['visibility']).to eq('private')
      expect(record.defaults['spoiler']).to eq('enabled' => false)
      expect(record.defaults['language']).to eq('mode' => 'auto')
      expect(record.managed['hashtags'].first['normalized_name']).to eq('ruby')
      expect(record.user_id).to eq(owner.id)

      get :edit, params: { id: record.id }
      expect(response.body).to include('Field notes')
      expect(response.body).to include(I18n.t('user_posting_contexts.sources.clear'))

      patch :update, params: { id: record.id, user_posting_context: style_params(name: 'Renamed', lock_version: record.lock_version, target_kind: 'group', target_account_id: group.id, visibility_choice: 'explicit', visibility_value: 'private') }
      expect(response).to redirect_to(settings_user_posting_contexts_path)
      expect(record.reload.name).to eq('Renamed')
      expect(record.target_account).to eq(group)
      expect(record.defaults['visibility']).to eq('private')

      expect do
        post :duplicate, params: { id: record.id }
      end.to change { owner.user_posting_contexts.count }.by(1)
      copy = owner.user_posting_contexts.ordered.last
      expect(copy.id).not_to eq(record.id)
      expect(copy.defaults).to eq(record.defaults)
      expect(copy.user_id).to eq(owner.id)

      get :edit, params: { id: foreign.id }
      expect(response).to have_http_status(:not_found)
      patch :update, params: { id: foreign.id, user_posting_context: style_params(name: 'Stolen') }
      expect(response).to have_http_status(:not_found)
      delete :destroy, params: { id: foreign.id }
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.name).to eq('Foreign')

      delete :destroy, params: { id: record.id }
      expect(owner.user_posting_contexts.exists?(record.id)).to be false
    end

    it 'does not accept an owner, storage version, or raw payload from the form' do
      record = owner.user_posting_contexts.create!(name: 'Field notes', defaults: { 'visibility' => 'unlisted' }, managed: { 'hashtags' => [] })
      other = Fabricate(:user)

      patch :update, params: {
        id: record.id,
        user_posting_context: style_params(lock_version: record.lock_version).merge(
          user_id: other.id,
          schema_version: 4,
          defaults: { 'visibility' => 'direct' },
          managed: { 'hashtags' => [{ 'name' => 'x', 'normalized_name' => 'x', 'enforcement' => 'required', 'rule_id' => 'group-follow' }] }
        ),
      }

      record.reload
      expect(record.user_id).to eq(owner.id)
      expect(record.schema_version).to eq(1)
      expect(record.defaults).not_to have_key('visibility')
      expect(record.managed['hashtags']).to eq([])
    end

    it 'keeps the entered visibility when the destination changes and reports the group conflict' do
      record = owner.user_posting_contexts.create!(name: 'Field notes', defaults: { 'visibility' => 'private' }, managed: { 'hashtags' => [] })

      patch :update, params: {
        id: record.id,
        user_posting_context: style_params(
          lock_version: record.lock_version,
          target_kind: 'group',
          target_account_id: group.id,
          target_hashtag: 'keep-me',
          visibility_choice: 'explicit',
          visibility_value: 'private',
          hashtags_text: 'fedibird'
        ),
      }

      record.reload
      expect(record.target_kind).to eq('group')
      expect(record.target_hashtag).to be_nil
      expect(record.defaults['visibility']).to eq('private')
      expect(record.managed['hashtags'].first['name']).to eq('fedibird')

      post :preview, params: {
        id: record.id,
        user_posting_context: style_params(
          target_kind: 'group',
          target_account_id: group.id,
          visibility_choice: 'explicit',
          visibility_value: 'private',
          hashtags_text: 'fedibird'
        ),
      }
      group_body = JSON.parse(response.body)
      expect(group_body['preview_html']).to include(I18n.t('statuses.visibilities.private'))
      expect(group_body['preview_html']).to include(I18n.t('user_posting_contexts.conflict_item', field: I18n.t('user_posting_contexts.preview_labels.visibility'), value: I18n.t('statuses.visibilities.private'), options: [I18n.t('statuses.visibilities.public'), I18n.t('statuses.visibilities.unlisted')].join(', ')))
      expect(group_body['constraint_html']).to include(I18n.t('user_posting_contexts.permissions.conflict', value: I18n.t('statuses.visibilities.private')))
      expect(group_body['preview_html']).not_to include('name="user_posting_context')
      expect(group_body['destination_html']).to include(I18n.t('user_posting_contexts.rules.mention', label: group.acct))
      expect(group_body['destination_html']).to include(I18n.t('user_posting_contexts.recommended_empty'))

      post :preview, params: {
        id: record.id,
        user_posting_context: style_params(
          target_kind: 'hashtag',
          target_hashtag: 'ruby',
          visibility_choice: 'explicit',
          visibility_value: 'private',
          hashtags_text: 'fedibird'
        ),
      }
      body = JSON.parse(response.body)
      expect(body['preview_html']).to include(I18n.t('statuses.visibilities.private'))
      expect(body['preview_html']).to include('fedibird')
      expect(body['preview_html']).to include('#ruby')
      expect(body['preview_html']).to include(I18n.t('user_posting_contexts.destination_hashtag_origin'))
      expect(body['preview_html']).to include(I18n.t('user_posting_contexts.advisory'))
      expect(body['preview_html']).not_to include(I18n.t('user_posting_contexts.preview_labels.recommended'))
      expect(body['destination_html']).to include(I18n.t('user_posting_contexts.destination_hashtag_origin'))
      expect(body['destination_html']).not_to include(I18n.t('user_posting_contexts.recommended_empty'))
      expect(record.reload.target_kind).to eq('group')
      expect(record.defaults['visibility']).to eq('private')
    end

    it 'does not overwrite a stale edit' do
      record = owner.user_posting_contexts.create!(name: 'Field notes')
      stale_lock = record.lock_version
      record.update!(name: 'Saved elsewhere')

      patch :update, params: { id: record.id, user_posting_context: style_params(name: 'Lost update', lock_version: stale_lock) }

      expect(response).to have_http_status(:conflict)
      expect(response.body).to include(I18n.t('user_posting_contexts.errors.stale'))
      expect(record.reload.name).to eq('Saved elsewhere')
      expect(response.body).to include(%(value="#{stale_lock}"))
    end

    it 'escapes style text and explains an unsupported group without calling it allowed' do
      hostile = owner.user_posting_contexts.create!(name: '<script>alert(1)</script>', purpose: '<img src=x onerror=alert(1)>')
      hostile.update_column(:icon, '<svg onload=alert(1)>')
      remote = Fabricate(:account, username: 'group', domain: 'example.com', actor_type: 'Group')

      get :index
      expect(response.body).not_to include('<script>alert(1)</script>')
      expect(response.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
      expect(response.body).not_to include('<img src=x onerror=alert(1)>')
      expect(response.body).to include('&lt;img src=x onerror=alert(1)&gt;')

      get :edit, params: { id: hostile.id }
      expect(response.body).not_to include('<svg onload=alert(1)>')

      expect(ResolveAccountService).not_to receive(:new)
      post :preview, params: {
        user_posting_context: style_params(target_kind: 'group', target_account_id: remote.id, visibility_choice: 'explicit', visibility_value: 'public'),
      }
      body = JSON.parse(response.body)
      expect(body['constraint_html']).to include(I18n.t('user_posting_contexts.unverified_banner'))
      expect(body['preview_html']).not_to include(I18n.t('user_posting_contexts.permissions.permitted', options: 'Public'))
      expect(body['preview_html']).to include(I18n.t('user_posting_contexts.discovery.unsupported'))
      expect(body['preview_html']).not_to include(I18n.t('user_posting_contexts.recommended_empty'))
      expect(body['destination_html']).to include(I18n.t('user_posting_contexts.unverified_banner'))
      expect(body['destination_html']).not_to include(I18n.t('user_posting_contexts.recommended_empty'))
    end

    it 'stops a fifty-first style' do
      UserPostingContext::MAX_PER_USER.times { |index| owner.user_posting_contexts.create!(name: "Style #{index}") }

      expect do
        post :create, params: { user_posting_context: style_params(name: 'Overflow') }
      end.not_to change(UserPostingContext, :count)
      expect(response.body).to include('50')
    end
  end
end

describe Settings::ProfilesController do
  render_views

  it 'does not show the posting style link to a regular user' do
    sign_in Fabricate(:user), scope: :user
    get :show
    expect(response.body).not_to include(I18n.t('settings.user_posting_contexts'))
  end
end
