# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Embedded posting style settings' do # rubocop:disable Metrics/BlockLength
  let(:user) { user_with_role('Owner') }
  let(:style) { user.user_posting_contexts.create!(name: 'Notes', icon: '📝') }
  let(:options) { { embedded: '1' } }
  let(:attributes) { { name: 'Updated notes', target_kind: 'none', visibility_choice: 'inherit', language_choice: 'inherit', sensitive_choice: 'inherit', spoiler_choice: 'inherit', hashtags_text: '' } }
  let(:assignment) { UserPostingContextAssignment.assign!(user: user, surface_kind: 'hashtag', surface_key: 'ruby', style: style) }

  before do
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
    sign_in user
  end

  def framing
    response.headers.fetch('Content-Security-Policy')
  end

  def expect_embedded
    expect(response).to have_http_status(:ok)
    expect(framing).to include("frame-ancestors 'self'", "form-action 'self'", "base-uri 'none'")
    expect(response.headers['X-Frame-Options']).to eq('SAMEORIGIN')
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(response.body).to include('content="postingStyles"', 'embedded-settings')
    expect(response.body).not_to include('sidebar-wrapper')
  end

  it 'embeds only the administrator HTML pages with a distinct screen marker' do
    [settings_user_posting_contexts_path, new_settings_user_posting_context_path, edit_settings_user_posting_context_path(style), confirm_destroy_settings_user_posting_context_path(style), settings_user_posting_context_assignments_path].each do |path|
      get path, params: options
      expect_embedded
      doc = Nokogiri::HTML(response.body)
      doc.css('a[href], form[action]').each do |node|
        url = node['href'] || node['action']
        expect(url).to include('embedded=1') if url.start_with?('/settings/user_posting_context')
      end
    end
    get edit_settings_user_posting_context_path(style), params: options
    expect(Nokogiri::HTML(response.body).at_css('[data-preview-url]')['data-preview-url']).to include('preview?embedded=1')
  end

  it 'leaves normal and non-opted-in pages framed DENY' do
    [nil, '0', 'true'].each do |mode|
      get settings_user_posting_contexts_path, params: { embedded: mode }
      expect(framing).to include("frame-ancestors 'none'")
      expect(response.body).to include('sidebar-wrapper')
    end
    get '/settings/preferences', params: options
    expect(framing).to include("frame-ancestors 'none'")
  end

  it 'overrides production DENY only for an opted-in administrator HTML render' do
    original = ActionDispatch::Response.default_headers
    ActionDispatch::Response.default_headers = original.merge('X-Frame-Options' => 'DENY')
    begin
      get settings_user_posting_contexts_path, params: options
      expect_embedded
      get settings_user_posting_contexts_path
      expect(response.headers['X-Frame-Options']).to eq('DENY')
      get new_user_session_path, params: options
      expect(response.headers['X-Frame-Options']).to eq('DENY')
    ensure
      ActionDispatch::Response.default_headers = original
    end
  end

  it 'retains the embedded redirect for create, update, duplicate and delete' do
    expect { post settings_user_posting_contexts_path(options), params: { user_posting_context: attributes } }.to change { user.user_posting_contexts.count }.by(1)
    expect(response).to redirect_to(settings_user_posting_contexts_path(options))
    expect(framing).to include("frame-ancestors 'none'")
    follow_redirect!
    expect_embedded
    patch settings_user_posting_context_path(style, options), params: { user_posting_context: attributes.merge(lock_version: style.lock_version) }
    expect(response).to redirect_to(settings_user_posting_contexts_path(options))
    expect(style.reload.name).to eq('Updated notes')
    expect { post duplicate_settings_user_posting_context_path(style, options) }.to change { user.user_posting_contexts.count }.by(1)
    copy = user.user_posting_contexts.order(:id).last
    expect(response).to redirect_to(edit_settings_user_posting_context_path(copy, options))
    assignment
    delete settings_user_posting_context_path(style, options)
    expect(response).to redirect_to(settings_user_posting_contexts_path(options))
    expect(assignment.reload.user_posting_context_id).to be_nil
  end

  it 'renders validation HTML in mode and a stale 409 with its original lock version, without frame permission' do
    post settings_user_posting_contexts_path(options), params: { user_posting_context: attributes.merge(name: '') }
    expect_embedded
    expect(response.body).to include('error')
    stale = style.lock_version
    style.update!(name: 'Elsewhere')
    patch settings_user_posting_context_path(style, options), params: { user_posting_context: attributes.merge(lock_version: stale) }
    expect(response).to have_http_status(:conflict)
    expect(framing).to include("frame-ancestors 'none'")
    expect(response.body).to include('content="postingStyles"', 'embedded-settings')
    expect(Nokogiri::HTML(response.body).at_css('[name="user_posting_context[lock_version]"]')['value']).to eq(stale.to_s)
    expect(style.reload.name).to eq('Elsewhere')
  end

  it 'keeps POST preview as JSON and denies framing' do
    post preview_settings_user_posting_contexts_path(options), params: { id: style.id, user_posting_context: attributes }, headers: { 'ACCEPT' => 'application/json', 'X-Requested-With' => 'XMLHttpRequest' }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/json')
    expect(response.parsed_body.keys).to contain_exactly('preview_html', 'constraint_html', 'destination_html')
    expect(framing).to include("frame-ancestors 'none'")
    expect(style.reload.name).to eq('Notes')
  end

  it 'preserves assignment filtering, paging, release and decline with embedded redirects' do
    assignment
    21.times { |i| UserPostingContextAssignment.assign!(user: user, surface_kind: 'hashtag', surface_key: "tag#{i}", style: style) }
    query = options.merge(user_posting_context_id: style.id, page: '2')
    get settings_user_posting_context_assignments_path, params: query
    expect_embedded
    expect(Nokogiri::HTML(response.body).css('article.user-posting-assignment').count).to eq(2)
    expect(response.body).to include('embedded=1', "user_posting_context_id=#{style.id}")
    post decline_settings_user_posting_context_assignment_path(assignment, options), params: { lock_version: assignment.lock_version, user_posting_context_id: style.id, page: '2' }
    expect(response).to redirect_to(settings_user_posting_context_assignments_path(query))
    expect(assignment.reload.user_posting_context_id).to be_nil
    post release_settings_user_posting_context_assignment_path(assignment, options), params: { lock_version: assignment.lock_version }
    expect(response).to redirect_to(settings_user_posting_context_assignments_path(options))
    expect(UserPostingContextAssignment.exists?(assignment.id)).to be false
  end

  it 'keeps assignment conflicts in a marked 409 without framing' do
    stale = assignment.lock_version
    assignment.decline!(stale)
    post release_settings_user_posting_context_assignment_path(assignment, options), params: { lock_version: stale }
    expect(response).to have_http_status(:conflict)
    expect(response.body).to include('content="postingStyles"')
    expect(framing).to include("frame-ancestors 'none'")
  end

  it 'rejects other users resources and preview records' do
    other = Fabricate(:user)
    foreign = other.user_posting_contexts.create!(name: 'Foreign')
    foreign_assignment = UserPostingContextAssignment.assign!(user: other, surface_kind: 'hashtag', surface_key: 'secret', style: foreign)
    [[:get, edit_settings_user_posting_context_path(foreign)], [:get, confirm_destroy_settings_user_posting_context_path(foreign)], [:patch, settings_user_posting_context_path(foreign)], [:post, duplicate_settings_user_posting_context_path(foreign)], [:delete, settings_user_posting_context_path(foreign)], [:post, release_settings_user_posting_context_assignment_path(foreign_assignment)], [:post, decline_settings_user_posting_context_assignment_path(foreign_assignment)], [:get, settings_user_posting_context_assignments_path(user_posting_context_id: foreign.id)], [:post, preview_settings_user_posting_contexts_path(id: foreign.id)]].each do |method, path|
      public_send(method, path, params: options.merge(user_posting_context: attributes))
      expect(response).to have_http_status(:not_found)
      expect(framing).to include("frame-ancestors 'none'")
    end
    expect(foreign.reload.name).to eq('Foreign')
  end

  [nil, 'User', 'Admin'].each do |role|
    it "rejects unauthenticated/non-administrator #{role.inspect} without framing" do
      style
      assignment
      sign_out user
      sign_in(role == 'User' ? Fabricate(:user) : user_with_role(role)) if role
      [[:get, settings_user_posting_contexts_path], [:get, new_settings_user_posting_context_path], [:get, edit_settings_user_posting_context_path(style)], [:post, settings_user_posting_contexts_path], [:patch, settings_user_posting_context_path(style)], [:post, duplicate_settings_user_posting_context_path(style)], [:delete, settings_user_posting_context_path(style)], [:post, preview_settings_user_posting_contexts_path], [:get, settings_user_posting_context_assignments_path], [:post, release_settings_user_posting_context_assignment_path(assignment)], [:post, decline_settings_user_posting_context_assignment_path(assignment)]].each do |method, path|
        public_send(method, path, params: options.merge(user_posting_context: attributes))
        expect(response.status).to eq(role ? 403 : 302)
        expect(framing).to include("frame-ancestors 'none'")
      end
      unless role
        get new_user_session_path, params: options
        expect(framing).to include("frame-ancestors 'none'")
      end
    end
  end

  context 'with real CSRF verification' do
    around do |example|
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    it 'rejects missing tokens for create, update, duplicate, delete, preview, release and decline' do
      [[:post, settings_user_posting_contexts_path], [:patch, settings_user_posting_context_path(style)], [:post, duplicate_settings_user_posting_context_path(style)], [:delete, settings_user_posting_context_path(style)], [:post, preview_settings_user_posting_contexts_path], [:post, release_settings_user_posting_context_assignment_path(assignment)], [:post, decline_settings_user_posting_context_assignment_path(assignment)]].each do |method, path|
        public_send(method, path, params: options.merge(user_posting_context: attributes))
        expect(response).to have_http_status(:unprocessable_entity)
        expect(framing).to include("frame-ancestors 'none'")
      end
    end

    it 'accepts the existing embedded form CSRF token' do
      get new_settings_user_posting_context_path, params: options
      token = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')['content']
      expect { post settings_user_posting_contexts_path(options), params: { authenticity_token: token, user_posting_context: attributes } }.to change { user.user_posting_contexts.count }.by(1)
      expect(response).to redirect_to(settings_user_posting_contexts_path(options))
    end
  end
end
