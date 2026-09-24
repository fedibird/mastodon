# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin trends web UI', type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  before do
    %i(javascript_pack_tag stylesheet_pack_tag image_pack_tag preload_pack_asset).each do |method|
      allow_any_instance_of(ActionView::Base).to receive(method).and_return('')
    end
  end

  def taxonomist_role
    UserRole.create!(
      name: "Trends ui #{SecureRandom.hex(4)}",
      position: UserRole.maximum(:position).to_i + 1,
      permissions_as_keys: %w(manage_taxonomies)
    )
  end

  let(:taxonomist) { user_with_role(taxonomist_role) }
  let(:reporter) do
    user_with_role(
      UserRole.create!(
        name: "Reports only #{SecureRandom.hex(4)}",
        position: UserRole.maximum(:position).to_i + 1,
        permissions_as_keys: %w(manage_reports)
      )
    )
  end

  describe Admin::Trends::TagsController do
    let!(:tag) { Fabricate(:tag, name: 'shown', display_name: 'Shown', trendable: true, reviewed_at: Time.now.utc) }

    before { redis.zadd('trending_tags:all', 3, tag.id) }

    it 'renders trending tags for a manage_taxonomies role' do
      sign_in taxonomist, scope: :user

      get :index

      expect(response).to have_http_status(200)
      expect(response.body).to include('Shown')
      expect(response.body).not_to include('>shown<')
    end

    it 'filters pending review outside the trending set' do
      pending = Fabricate(:tag, name: 'waiting', display_name: 'Waiting', reviewed_at: nil, requested_review_at: Time.now.utc)
      sign_in taxonomist, scope: :user

      get :index, params: { status: 'pending_review' }

      expect(response).to have_http_status(200)
      expect(response.body).to include('Waiting')
      expect(response.body).not_to include('Shown')
      expect(pending.requires_review?).to be true
    end

    it 'denies a role without manage_taxonomies' do
      sign_in reporter, scope: :user

      get :index, format: :json

      expect(response).to have_http_status(403)
    end

    it 'alerts when a batch has no selection and approves a selected tag' do
      sign_in taxonomist, scope: :user

      post :batch
      expect(response).to redirect_to(admin_trends_tags_path(page: nil))
      expect(flash[:alert]).to eq I18n.t('admin.trends.tags.no_tag_selected')

      post :batch, params: { approve: '1', trends_tag_batch: { tag_ids: [tag.id] } }
      expect(response).to redirect_to(admin_trends_tags_path(page: nil))
      expect(tag.reload[:trendable]).to be true
      expect(tag.reviewed_at).to be_present
    end
  end

  describe Admin::Trends::LinksController do
    let!(:card) { Fabricate(:preview_card, title: 'Link title', language: 'en', url: 'https://links.example/a') }

    before do
      PreviewCardTrend.create!(preview_card: card, score: 4, rank: 1, allowed: false, language: 'en')
    end

    it 'renders every link by default and can limit to allowed links' do
      sign_in taxonomist, scope: :user

      get :index
      expect(response).to have_http_status(200)
      expect(response.body).to include('Link title')
      expect(response.body).to include(admin_trends_links_preview_card_providers_path)

      card.update!(trendable: true)
      card.trend.update!(allowed: true)
      other = Fabricate(:preview_card, title: 'Other link', language: 'ja')
      PreviewCardTrend.create!(preview_card: other, score: 1, rank: 2, allowed: false, language: 'ja')

      get :index, params: { trending: 'allowed', locale: 'en' }
      expect(response.body).to include('Link title')
      expect(response.body).not_to include('Other link')
    end

    it 'denies a role without manage_taxonomies' do
      sign_in reporter, scope: :user

      get :index, format: :json
      expect(response).to have_http_status(403)
    end

    it 'alerts when a batch has no selection and rejects the selected link' do
      sign_in taxonomist, scope: :user

      post :batch
      expect(flash[:alert]).to eq I18n.t('admin.trends.links.no_link_selected')

      post :batch, params: { reject: '1', trends_preview_card_batch: { preview_card_ids: [card.id] } }
      expect(card.reload[:trendable]).to be false
    end
  end

  describe Admin::Trends::StatusesController do
    let(:account) { Fabricate(:account) }
    let!(:status) { Fabricate(:status, account: account, text: 'Trend status text', language: 'en') }

    before do
      StatusTrend.create!(status: status, account: account, score: 4, rank: 1, allowed: true, language: 'en')
    end

    it 'renders trending statuses and filters by locale' do
      sign_in taxonomist, scope: :user

      get :index
      expect(response).to have_http_status(200)
      expect(response.body).to include('Trend status text')

      get :index, params: { locale: 'ja', trending: 'allowed' }
      expect(response.body).not_to include('Trend status text')
    end

    it 'denies a role without manage_taxonomies' do
      sign_in reporter, scope: :user

      get :index, format: :json
      expect(response).to have_http_status(403)
    end

    it 'alerts when a batch has no selection and approves the selected status' do
      sign_in taxonomist, scope: :user

      post :batch
      expect(flash[:alert]).to eq I18n.t('admin.trends.statuses.no_status_selected')

      post :batch, params: { approve: '1', trends_status_batch: { status_ids: [status.id] } }
      expect(status.reload[:trendable]).to be true
      expect(account.reload.reviewed_at).to be_nil
    end
  end

  describe Admin::Trends::Links::PreviewCardProvidersController do
    let!(:provider) { PreviewCardProvider.create!(domain: 'ui.example', trendable: nil, reviewed_at: nil) }

    it 'renders publishers for a manage_taxonomies role' do
      sign_in taxonomist, scope: :user

      get :index, params: { status: 'pending_review' }

      expect(response).to have_http_status(200)
      expect(response.body).to include('ui.example')
    end

    it 'denies a role without manage_taxonomies' do
      sign_in reporter, scope: :user

      get :index, format: :json
      expect(response).to have_http_status(403)
    end

    it 'alerts when a batch has no selection and approves the selected publisher' do
      sign_in taxonomist, scope: :user

      post :batch
      expect(flash[:alert]).to eq I18n.t('admin.trends.links.publishers.no_publisher_selected')

      post :batch, params: { approve: '1', trends_preview_card_provider_batch: { preview_card_provider_ids: [provider.id] } }
      expect(provider.reload[:trendable]).to be true
      expect(provider.reviewed_at).to be_present
    end
  end
end
