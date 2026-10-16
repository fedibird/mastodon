# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Embedded Rails filter settings' do
  let(:user) { Fabricate(:user) }
  let(:filter) { Fabricate(:custom_filter, account: user.account) }
  let(:attributes) { { title: 'Quiet words', context: ['home'], filter_action: 'hide', keywords_attributes: { '0' => { keyword: 'spoiler', whole_word: '1' } } } }

  before do
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
    sign_in user
  end

  def directives
    response.headers.fetch('Content-Security-Policy').split(';').map(&:strip)
  end

  def expect_embedded
    expect(response).to have_http_status(:ok)
    expect(directives).to include("frame-ancestors 'self'", "form-action 'self'", "base-uri 'none'")
    expect(response.headers['X-Frame-Options']).to eq('SAMEORIGIN')
    expect(response.headers['Cache-Control']).to include('private', 'no-store')
    expect(response.body).to include('name="embedded-rails-settings"', 'embedded-settings', 'admin.js', 'public.js')
    expect(response.body).not_to include('sidebar-wrapper')
  end

  [false, true].each do |embedded|
    context "with embedded=#{embedded}" do
      let(:options) { embedded ? { embedded: '1' } : {} }

      it 'renders index, new, edit and statuses with the appropriate layout and policy' do
        [filters_path, new_filter_path, edit_filter_path(filter), filter_statuses_path(filter)].each do |path|
          get path, params: options
          if embedded
            expect_embedded
          else
            expect(response).to have_http_status(:ok)
            expect(directives).to include("frame-ancestors 'none'")
            expect(response.body).to include('sidebar-wrapper')
          end
        end
      end

      it 'creates using the existing nested keyword form and keeps the redirect mode' do
        expect { post filters_path(options), params: { custom_filter: attributes } }.to change { user.account.custom_filters.count }.by(1)
        expect(response).to redirect_to(filters_path(options))
        created = user.account.custom_filters.last
        expect(created.keywords.first.keyword).to eq('spoiler')
        expect(created.keywords.first.whole_word).to be true
        expect(created).to be_hide_action
        follow_redirect!
        if embedded
          expect_embedded
        else
          expect(directives).to include("frame-ancestors 'none'")
        end
      end

      it 'updates title, action, keyword and expiration without changing the normal redirect' do
        put filter_path(filter, options), params: { custom_filter: attributes.merge(expires_in: '3600') }
        expect(response).to redirect_to(filters_path(options))
        expect(filter.reload.title).to eq('Quiet words')
        expect(filter.expires_at).to be_within(10.seconds).of(1.hour.from_now)
        expect(filter.keywords.first.keyword).to eq('spoiler')
      end

      it 'renders invalid create and update with the same form mode' do
        [[:post, filters_path(options)], [:put, filter_path(filter, options)]].each do |method, path|
          public_send(method, path, params: { custom_filter: { title: '', context: ['home'] } })
          expect(response).to have_http_status(:ok)
          expect(response.body).to include('error')
          document = Nokogiri::HTML(response.body)
          action = document.at_css('form.simple_form')['action']
          expect(URI.parse(action).query).to eq(embedded ? 'embedded=1' : nil)
          expect_embedded if embedded
        end
      end

      it 'deletes and keeps the redirect mode' do
        filter
        expect { delete filter_path(filter, options) }.to change(CustomFilter, :count).by(-1)
        expect(response).to redirect_to(filters_path(options))
      end

      it 'removes selected posts using batch, with the existing owner scope' do
        attached = Fabricate(:custom_filter_status, custom_filter: filter, status: Fabricate(:status, account: user.account))
        other_filter = Fabricate(:custom_filter, account: user.account)
        untouched = Fabricate(:custom_filter_status, custom_filter: other_filter, status: Fabricate(:status, account: user.account))
        post batch_filter_statuses_path(filter, options), params: { remove: '', form_status_filter_batch_action: { status_filter_ids: [attached.id, untouched.id] } }
        expect(response).to redirect_to(edit_filter_path(filter, options))
        expect(CustomFilterStatus.exists?(attached.id)).to be false
        expect(CustomFilterStatus.exists?(untouched.id)).to be true
      end

      it 'preserves mode and flash when no posts are selected' do
        post batch_filter_statuses_path(filter, options), params: { remove: '' }
        expect(response).to redirect_to(edit_filter_path(filter, options))
        follow_redirect!
        expect(response.body).to include(I18n.t('admin.statuses.no_status_selected'))
      end
    end
  end

  it 'keeps embedded links, form actions and pagination inside the filter routes' do
    21.times { Fabricate(:custom_filter_status, custom_filter: filter, status: Fabricate(:status, account: user.account)) }
    get filters_path, params: { embedded: '1' }
    expect(response.body).to include(new_filter_path(embedded: '1'), edit_filter_path(filter, embedded: '1'), filter_path(filter, embedded: '1'))
    get edit_filter_path(filter), params: { embedded: '1' }
    expect(response.body).to include(filter_statuses_path(filter, embedded: '1'), 'add_fields', 'remove_fields')
    get filter_statuses_path(filter), params: { embedded: '1' }
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('form')['action']).to eq(batch_filter_statuses_path(filter, embedded: '1'))
    expect(document.css('.pagination a').map { |a| a['href'] }).not_to be_empty
    document.css('.pagination a').each { |a| expect(Rack::Utils.parse_query(URI.parse(a['href']).query)).to include('embedded' => '1') }
    document.css('.detailed-status__meta a').each { |a| expect(a['target']).to eq('_blank') }
  end

  it 'overrides production DENY only for successful embedded filter HTML' do
    original = ActionDispatch::Response.default_headers
    ActionDispatch::Response.default_headers = original.merge('X-Frame-Options' => 'DENY')
    begin
      get filters_path, params: { embedded: '1' }
      expect_embedded
      get filters_path
      expect(response.headers['X-Frame-Options']).to eq('DENY')
      expect(directives).to include("frame-ancestors 'none'")
      get new_user_session_path, params: { embedded: '1' }
      expect(directives).to include("frame-ancestors 'none'")
      expect(response.headers['X-Frame-Options']).to eq('DENY')
    ensure
      ActionDispatch::Response.default_headers = original
    end
  end

  it 'does not enable embedding for an arbitrary mode value or non-HTML request' do
    ['true', 'https://example.com', '0'].each do |value|
      get filters_path, params: { embedded: value }
      expect(directives).to include("frame-ancestors 'none'")
    end
    get filters_path(format: :json), params: { embedded: '1' }
    expect(directives).to include("frame-ancestors 'none'")
  end

  it 'does not accept a redirect destination' do
    post filters_path(embedded: '1'), params: { custom_filter: attributes, return_to: 'https://example.com', url: '//example.com' }
    expect(response).to redirect_to(filters_path(embedded: '1'))
    expect(directives).to include("frame-ancestors 'none'")
  end

  it 'keeps unrelated settings unembeddable' do
    get '/settings/preferences', params: { embedded: '1' }
    expect(directives).to include("frame-ancestors 'none'")
  end

  it 'rejects another account’s filter for reads and all mutations' do
    other = Fabricate(:custom_filter)
    [[:get, edit_filter_path(other)], [:put, filter_path(other)], [:delete, filter_path(other)], [:get, filter_statuses_path(other)], [:post, batch_filter_statuses_path(other)]].each do |method, path|
      public_send(method, path, params: { embedded: '1', custom_filter: attributes })
      expect(response).to have_http_status(:not_found)
      expect(directives).to include("frame-ancestors 'none'")
    end
    expect(CustomFilter.exists?(other.id)).to be true
  end

  it 'requires authentication for pages and mutations, leaving login unembeddable' do
    filter
    sign_out user
    [[:get, filters_path], [:get, new_filter_path], [:get, edit_filter_path(filter)], [:post, filters_path], [:put, filter_path(filter)], [:delete, filter_path(filter)], [:get, filter_statuses_path(filter)], [:post, batch_filter_statuses_path(filter)]].each do |method, path|
      public_send(method, path, params: { embedded: '1', custom_filter: attributes })
      expect(response).to redirect_to(new_user_session_path)
      expect(directives).to include("frame-ancestors 'none'")
    end
    follow_redirect!
    expect(directives).to include("frame-ancestors 'none'")
  end

  context 'with real CSRF verification' do
    around do |example|
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    it 'rejects missing tokens for every mutation' do
      [[:post, filters_path], [:put, filter_path(filter)], [:delete, filter_path(filter)], [:post, batch_filter_statuses_path(filter)]].each do |method, path|
        public_send(method, path, params: { embedded: '1', custom_filter: attributes })
        expect(response).to have_http_status(:unprocessable_entity)
        expect(directives).to include("frame-ancestors 'none'")
      end
    end

    it 'accepts the token from the embedded Rails form' do
      get new_filter_path, params: { embedded: '1' }
      token = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')['content']
      expect { post filters_path(embedded: '1'), params: { authenticity_token: token, custom_filter: attributes } }.to change(CustomFilter, :count).by(1)
      expect(response).to redirect_to(filters_path(embedded: '1'))
    end
  end
end
