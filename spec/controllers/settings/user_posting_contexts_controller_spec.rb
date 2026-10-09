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
      expect(copy.name).to eq(UserPostingContext.copied_name(record.name))
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

    it 'previews without loading the group choice list' do
      expect(Account).not_to receive(:local)

      post :preview, params: { user_posting_context: style_params(name: 'Quiet', purpose: 'A note', icon: '✎', target_kind: 'none') }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['preview_html']).to include(I18n.t('user_posting_contexts.save_not_posting'))
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

    it 'shows active places on the card without nesting those links, and separates unusable defaults' do
      groups = Array.new(4) { |index| Fabricate(:account, username: "squad#{index}", actor_type: 'Group') }
      style = owner.user_posting_contexts.create!(name: 'Field notes', icon: '📝')
      groups.each do |account|
        UserPostingContextAssignment.assign!(user: owner, surface_kind: 'group', surface_key: account.id.to_s, style: style)
      end
      owner.user_posting_contexts.create!(name: 'Unused')
      blocked = owner.user_posting_contexts.create!(name: 'Blocked', target_kind: 'hashtag', target_hashtag: 'beta')
      UserPostingContextAssignment.assign!(user: owner, surface_kind: 'hashtag', surface_key: 'beta', style: blocked)
      blocked.update!(target_hashtag: 'alpha')

      expect(PostingContext::DiscoveryService).not_to receive(:new)
      expect(ResolveAccountService).not_to receive(:new)
      expect(UserPostingContext::Preview).not_to receive(:build)

      get :index

      document = Nokogiri::HTML(response.body)
      card = document.css('.user-posting-context-card').find { |node| node.at_css('h3').text == 'Field notes' }
      usage_links = card.css('.user-posting-context-card__usage a')

      expect(card.at_css('a.user-posting-context-card__main').css('a')).to be_empty
      expect(usage_links.map { |link| link.text.strip }).to include(I18n.t('user_posting_context_assignments.used_as_default', count: 4))
      expect(usage_links.map { |link| link.text.strip }).to include(I18n.t('user_posting_context_assignments.see_all'))
      expect(card.css('.user-posting-context-card__places li').size).to eq(3)
      expect(card.text).to include('squad0')
      expect(card.text).not_to include('squad3')
      expect(usage_links.first['href']).to include("user_posting_context_id=#{style.id}")
      expect(document.css('.user-posting-context-card').find { |node| node.at_css('h3').text == 'Unused' }.at_css('.user-posting-context-card__usage')).to be_nil
      blocked_card = document.css('.user-posting-context-card').find { |node| node.at_css('h3').text == 'Blocked' }
      expect(blocked_card.text).to include(I18n.t('user_posting_context_assignments.unavailable_defaults'))
      expect(blocked_card.text).not_to include(I18n.t('user_posting_context_assignments.used_as_default', count: 1))
      expect(document.at_css('details.user-posting-context-card__menu summary')).to be_present
      expect(response.body).to include(I18n.t('user_posting_contexts.duplicate'))
    end

    it 'warns how many defaults a deleted style will turn into none, including unusable ones' do
      listed = Fabricate(:list, account: owner.account, title: 'Reading')
      style = owner.user_posting_contexts.create!(name: 'Field notes')
      UserPostingContextAssignment.assign!(user: owner, surface_kind: 'group', surface_key: group.id.to_s, style: style)
      UserPostingContextAssignment.assign!(user: owner, surface_kind: 'hashtag', surface_key: 'field', style: style)
      UserPostingContextAssignment.assign!(user: owner, surface_kind: 'list', surface_key: listed.id.to_s, style: style)
      style.update!(enabled: false)

      get :confirm_destroy, params: { id: style.id }

      expect(response.body).to include(ERB::Util.html_escape(I18n.t('user_posting_contexts.delete_confirm_with_defaults', name: 'Field notes', count: 3)))

      expect { delete :destroy, params: { id: style.id } }.not_to change(UserPostingContextAssignment, :count)
      rows = owner.user_posting_context_assignments
      expect(rows.map(&:user_posting_context_id).uniq).to eq([nil])
      expect(rows.map(&:availability_status).uniq).to eq(['none'])

      quiet = owner.user_posting_contexts.create!(name: 'Quiet')
      get :confirm_destroy, params: { id: quiet.id }
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('user_posting_contexts.delete_confirm', name: 'Quiet')))
      expect(response.body).not_to include('is the default in')
    end

    it 'does not query once per assignment while rendering style cards' do
      style = owner.user_posting_contexts.create!(name: 'Field notes')
      2.times do |index|
        UserPostingContextAssignment.assign!(user: owner, surface_kind: 'hashtag', surface_key: "card#{index}", style: style)
      end
      statements = lambda do
        queries = []
        callback = lambda do |_name, _started, _finished, _unique_id, payload|
          sql = payload[:sql].to_s
          next if payload[:cached] || payload[:name] == 'SCHEMA'
          next if sql.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

          queries << sql
        end
        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { get :index }
        queries.size
      end
      get :index
      small = statements.call
      10.times do |index|
        UserPostingContextAssignment.assign!(user: owner, surface_kind: 'hashtag', surface_key: "extra#{index}", style: style)
      end

      expect(statements.call).to eq(small)
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
