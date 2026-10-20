# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Embedded posting style settings' do # rubocop:disable Metrics/BlockLength
  let(:user) { Fabricate(:user, role: UserRole.find_by!(name: 'Owner')) }
  let(:style) { user.user_posting_contexts.create!(name: 'Notes') }
  let(:assignment) { UserPostingContextAssignment.assign!(user: user, surface_kind: 'hashtag', surface_key: 'books', style: style) }
  let(:options) { { embedded: '1' } }
  let(:attributes) { { name: 'Renamed', target_kind: 'none', visibility_choice: 'inherit', language_choice: 'inherit', sensitive_choice: 'inherit', spoiler_choice: 'inherit' } }

  around do |example|
    original = ActionDispatch::Response.default_headers
    ActionDispatch::Response.default_headers = original.merge('X-Frame-Options' => 'DENY')
    example.run
  ensure
    ActionDispatch::Response.default_headers = original
  end

  before do
    # .env.test sets LOCAL_HTTPS, so the session and Devise cookies are Secure.
    # An HTTP request spec would drop them on the next request and redirect to
    # sign-in. Match the cookie scheme instead of stubbing the user.
    https! if ENV['LOCAL_HTTPS'] == 'true'
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(Webpacker.instance.manifest).to receive(:lookup!, &resolver)
    allow(Webpacker.instance.manifest).to receive(:lookup, &resolver)
    sign_in user
  end

  def expect_blocked
    expect(response.headers.fetch('Content-Security-Policy')).to include("frame-ancestors 'none'")
    expect(response.headers['X-Frame-Options']).not_to eq('SAMEORIGIN')
  end

  def expect_embedded
    expect(response).to have_http_status(:ok)
    expect(response.headers.fetch('Content-Security-Policy')).to include("frame-ancestors 'self'", "form-action 'self'", "base-uri 'none'")
    expect(response.headers['X-Frame-Options']).to eq('SAMEORIGIN')
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(response.body).to include('content="postingStyles"', 'embedded-settings', 'admin.js', 'public.js')
    expect(response.body).not_to include('sidebar-wrapper')
  end

  it 'opts in only administrator HTML, keeping normal UI, login, JSON and invalid modes blocked under production DENY' do
    original = ActionDispatch::Response.default_headers
    ActionDispatch::Response.default_headers = original.merge('X-Frame-Options' => 'DENY')
    begin
      [settings_user_posting_contexts_path, new_settings_user_posting_context_path, edit_settings_user_posting_context_path(style), confirm_destroy_settings_user_posting_context_path(style), settings_user_posting_context_assignments_path].each do |path|
        get path, params: options
        expect_embedded
        get path
        expect_blocked
        expect(response.headers['X-Frame-Options']).to eq('DENY')
        expect(response.body).to include('sidebar-wrapper')
      end
      %w(true 0).each do |mode|
        get settings_user_posting_contexts_path, params: { embedded: mode }
        expect_blocked
      end
      get new_user_session_path, params: options
      expect_blocked
      post preview_settings_user_posting_contexts_path(format: :json), params: options.merge(user_posting_context: attributes)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include('preview_html', 'constraint_html', 'destination_html')
      expect_blocked
    ensure
      ActionDispatch::Response.default_headers = original
    end
  end

  it 'preserves mode through CRUD, duplicate, validation and delete confirmation without accepting return URLs' do
    expect { post settings_user_posting_contexts_path(options), params: { user_posting_context: attributes, return_to: 'https://evil.test' } }.to change(UserPostingContext, :count).by(1)
    expect(response).to redirect_to(settings_user_posting_contexts_path(options))
    expect_blocked
    follow_redirect!
    expect_embedded
    patch settings_user_posting_context_path(style, options), params: { user_posting_context: attributes.merge(lock_version: style.lock_version) }
    expect(response).to redirect_to(settings_user_posting_contexts_path(options))
    expect(style.reload.name).to eq('Renamed')
    post duplicate_settings_user_posting_context_path(style, options)
    copy = user.user_posting_contexts.order(:id).last
    expect(response).to redirect_to(edit_settings_user_posting_context_path(copy, options))
    follow_redirect!
    expect_embedded
    [[:post, settings_user_posting_contexts_path(options)], [:patch, settings_user_posting_context_path(style, options)]].each do |method, path|
      public_send(method, path, params: { user_posting_context: attributes.merge(name: '') })
      expect_embedded
      document = Nokogiri::HTML(response.body)
      expect(document.at_css('form[data-user-posting-context-form]')['action']).to include('embedded=1')
      expect(document.at_css('form[data-preview-url]')['data-preview-url']).to include('embedded=1')
      expect(document.css('.error')).not_to be_empty
    end
    get confirm_destroy_settings_user_posting_context_path(style, options)
    expect_embedded
    expect(response.body).to include(settings_user_posting_context_path(style, options))
    assignment
    expect { delete settings_user_posting_context_path(style, options) }.to change(UserPostingContext, :count).by(-1)
    expect(response).to redirect_to(settings_user_posting_contexts_path(options))
    expect(assignment.reload.availability_status).to eq('none')
  end

  it 'renders a stale edit as protected HTML 409 without allowing it to be framed as a new document' do
    version = style.lock_version
    style.update!(name: 'Changed elsewhere')
    patch settings_user_posting_context_path(style, options), params: { user_posting_context: attributes.merge(lock_version: version) }
    expect(response).to have_http_status(:conflict)
    expect_blocked
    expect(response.body).to include('content="postingStyles"', 'main class="embedded-settings"', I18n.t('user_posting_contexts.errors.stale'))
    expect(style.reload.name).to eq('Changed elsewhere')
  end

  it 'keeps usage links, assignment paging, release/decline and their conflicts in the same screen' do
    21.times { |i| UserPostingContextAssignment.assign!(user: user, surface_kind: 'hashtag', surface_key: "tag#{i}", style: style) }
    get settings_user_posting_contexts_path(options)
    expect(response.body).to include('embedded=1', 'user_posting_context_id=')
    get settings_user_posting_context_assignments_path(options.merge(user_posting_context_id: style.id))
    expect_embedded
    doc = Nokogiri::HTML(response.body)
    expect(doc.css('.pagination a')).not_to be_empty
    doc.css('.pagination a, form').each do |node|
      query = Rack::Utils.parse_query(URI.parse(node['href'] || node['action']).query)
      expect(query).to include('embedded' => '1')
    end
    row = assignment
    post decline_settings_user_posting_context_assignment_path(row, options), params: { lock_version: row.lock_version, page: '2' }
    expect(response).to redirect_to(settings_user_posting_context_assignments_path(options.merge(page: '2')))
    expect(row.reload.availability_status).to eq('none')
    post release_settings_user_posting_context_assignment_path(row, options), params: { lock_version: row.lock_version - 1 }
    expect(response).to have_http_status(:conflict)
    expect_blocked
    expect(response.body).to include('content="postingStyles"', I18n.t('user_posting_context_assignments.stale'))
    post release_settings_user_posting_context_assignment_path(row, options), params: { lock_version: row.lock_version }
    expect(response).to redirect_to(settings_user_posting_context_assignments_path(options))
    expect(UserPostingContextAssignment.exists?(row.id)).to be false
  end

  def operations(record, row)
    [[:get, settings_user_posting_contexts_path], [:get, new_settings_user_posting_context_path], [:get, edit_settings_user_posting_context_path(record)], [:get, confirm_destroy_settings_user_posting_context_path(record)], [:post, settings_user_posting_contexts_path], [:post, update_usual_settings_user_posting_contexts_path], [:patch, settings_user_posting_context_path(record)], [:post, duplicate_settings_user_posting_context_path(record)], [:delete, settings_user_posting_context_path(record)], [:post, preview_settings_user_posting_contexts_path(format: :json)], [:get, settings_user_posting_context_assignments_path], [:post, release_settings_user_posting_context_assignment_path(row)], [:post, decline_settings_user_posting_context_assignment_path(row)]]
  end

  it 'rejects non-administrators and anonymous access for every route' do
    record = style
    row = assignment
    sign_out user
    [nil, Fabricate(:user), Fabricate(:user, role: UserRole.find_by!(name: 'Admin'))].each do |visitor|
      sign_in visitor if visitor
      operations(record, row).each do |method, path|
        public_send(method, path, params: options.merge(user_posting_context: attributes))
        if visitor
          expect(response).to have_http_status(:forbidden)
        else
          expect(response.status).to be_in([302, 401])
        end
        expect_blocked
      end
      sign_out visitor if visitor
    end
  end

  it 'scopes reads, preview and writes to the current administrator' do
    foreign_user = Fabricate(:user)
    foreign = foreign_user.user_posting_contexts.create!(name: 'Secret')
    row = UserPostingContextAssignment.assign!(user: foreign_user, surface_kind: 'hashtag', surface_key: 'private', style: foreign)
    operations(foreign, row).reject { |_method, path| [settings_user_posting_contexts_path, new_settings_user_posting_context_path, settings_user_posting_context_assignments_path, update_usual_settings_user_posting_contexts_path].include?(path) }.each do |method, path|
      public_send(method, path, params: options.merge(id: foreign.id, user_posting_context: attributes))
      expect(response).to have_http_status(:not_found)
      expect_blocked
    end
    get settings_user_posting_context_assignments_path(options.merge(user_posting_context_id: foreign.id))
    expect(response).to have_http_status(:not_found)
    expect_blocked
  end

  it 'does not save another user’s style as the usual style' do
    foreign_user = Fabricate(:user, role: UserRole.find_by!(name: 'Owner'))
    foreign = foreign_user.user_posting_contexts.create!(name: 'Secret')

    post update_usual_settings_user_posting_contexts_path, params: options.merge(style_id: foreign.id)

    expect(response).to redirect_to(settings_user_posting_contexts_path(options))
    expect(flash[:alert]).to eq(I18n.t('user_posting_contexts.usual_invalid'))
    expect(UserPostingContextAssignment.usual_for(user)).to be_nil
    expect(UserPostingContextAssignment.usual_for(foreign_user)).to be_nil
    expect(foreign.reload).to be_persisted
  end

  context 'with real CSRF verification' do
    around do |example|
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    it 'rejects all mutations without a token and accepts the embedded form token' do
      operations(style, assignment).reject { |method, _path| method == :get }.each do |method, path|
        public_send(method, path, params: options.merge(user_posting_context: attributes))
        expect(response).to have_http_status(:unprocessable_entity)
        expect_blocked
      end
      get new_settings_user_posting_context_path(options)
      token = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')['content']
      expect { post settings_user_posting_contexts_path(options), params: { authenticity_token: token, user_posting_context: attributes } }.to change(UserPostingContext, :count).by(1)
      expect(response).to redirect_to(settings_user_posting_contexts_path(options))
    end
  end
end
