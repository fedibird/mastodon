# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::KeywordSubscribesController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }

  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
  end

  # Column order in the index table: name, type, string, case, block, media,
  # hashtags, URLs, timeline, state, actions.
  def hashtag_column
    6
  end

  def url_column
    7
  end

  def create_subscription(**options)
    KeywordSubscribe.create!({ account: user.account, name: 'subscription', keyword: 'foo' }.merge(options))
  end

  describe 'GET #index' do
    it 'heads the hashtag and URL columns and keeps the row aligned with them' do
      create_subscription(match_hashtags: true, match_urls: false)

      get :index

      expect(response).to have_http_status(200)
      expect(response.body).to include I18n.t('simple_form.labels.keyword_subscribes.match_hashtags')
      expect(response.body).to include I18n.t('simple_form.labels.keyword_subscribes.match_urls')

      table = Nokogiri::HTML(response.body).css('table.table').first
      headers = table.css('thead th')
      cells = table.css('tbody tr').first.css('td')

      expect(cells.size).to eq headers.size
      expect(headers[hashtag_column].text.strip).to eq I18n.t('simple_form.labels.keyword_subscribes.match_hashtags')
      expect(headers[url_column].text.strip).to eq I18n.t('simple_form.labels.keyword_subscribes.match_urls')
      expect(cells[hashtag_column].css('.positive-hint').size).to eq 1
      expect(cells[url_column].css('.negative-hint').size).to eq 1
    end
  end

  describe 'GET #new' do
    it 'renders a checkbox for each option' do
      get :new

      expect(response).to have_http_status(200)
      expect(response.body).to include 'keyword_subscribe[match_hashtags]'
      expect(response.body).to include 'keyword_subscribe[match_urls]'
      expect(response.body).to include I18n.t('simple_form.labels.keyword_subscribe.match_hashtags')
      expect(response.body).to include I18n.t('simple_form.labels.keyword_subscribe.match_urls')
    end
  end

  describe 'POST #create' do
    it 'stores both options' do
      post :create, params: { keyword_subscribe: { name: 'both', keyword: 'foo', match_hashtags: '1', match_urls: '1' } }

      subscription = user.account.keyword_subscribes.find_by!(name: 'both')

      expect(response).to redirect_to settings_keyword_subscribes_path
      expect(subscription.match_hashtags).to be true
      expect(subscription.match_urls).to be true
    end

    it 'leaves both options off by default' do
      post :create, params: { keyword_subscribe: { name: 'plain', keyword: 'foo' } }

      subscription = user.account.keyword_subscribes.find_by!(name: 'plain')

      expect(subscription.match_hashtags).to be false
      expect(subscription.match_urls).to be false
    end
  end

  describe 'PUT #update' do
    it 'turns each option on and off' do
      subscription = create_subscription

      put :update, params: { id: subscription.id, keyword_subscribe: { name: 'subscription', keyword: 'foo', match_hashtags: '1', match_urls: '0' } }

      expect(response).to redirect_to settings_keyword_subscribes_path
      expect(subscription.reload.match_hashtags).to be true
      expect(subscription.match_urls).to be false

      put :update, params: { id: subscription.id, keyword_subscribe: { name: 'subscription', keyword: 'foo', match_hashtags: '0', match_urls: '1' } }

      expect(subscription.reload.match_hashtags).to be false
      expect(subscription.match_urls).to be true
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
