# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FiltersController do
  render_views

  let(:user) { Fabricate(:user) }
  let(:filter) { Fabricate(:custom_filter, account: user.account) }

  before do
    sign_in(user)
    stub_webpacker_manifest
  end

  describe 'GET #edit' do
    it 'marks the title input for the reusable emoji picker' do
      get :edit, params: { id: filter }

      expect(response).to have_http_status(200)
      expect(response.body).to include('data-emoji-picker="true"')
    end

    it 'hides the individual posts section when none are attached' do
      get :edit, params: { id: filter }

      expect(response).to have_http_status(200)
      expect(response.body).not_to include(I18n.t('filters.edit.statuses'))
    end

    it 'has English and Japanese keys for the individual posts UI' do
      %w(
        filters.edit.statuses
        filters.edit.statuses_hint_html
        filters.statuses.back_to_filter
        filters.statuses.batch.remove
        filters.statuses.index.hint
        filters.statuses.index.title
        filters.index.statuses
        filters.index.statuses_long
      ).each do |key|
        expect(I18n.exists?(key, :en)).to eq(true), "missing #{key} in en"
        expect(I18n.exists?(key, :ja)).to eq(true), "missing #{key} in ja"
      end
    end

    context 'with an attached status' do
      let!(:status_filter) { Fabricate(:custom_filter_status, custom_filter: filter, status: Fabricate(:status, account: user.account)) }

      it 'shows the individual posts section and link' do
        get :edit, params: { id: filter }

        expect(response).to have_http_status(200)
        expect(response.body).to include(I18n.t('filters.edit.statuses'))
        expect(response.body).to include(filter_statuses_path(filter))
      end

      it 'renders the individual posts section in Japanese' do
        user.update!(locale: 'ja')
        get :edit, params: { id: filter }

        expect(response).to have_http_status(200)
        expect(response.body).to include('個別の投稿')
        expect(response.body).to include('フィルターを確認または投稿を削除')
        expect(response.body).not_to include('translation missing')
      end
    end
  end

  describe 'GET #index' do
    it 'keeps the raw title as fallback inside a custom emoji marker' do
      filter.update!(title: 'Work :fedibird:')

      get :index

      expect(response).to have_http_status(200)
      expect(response.body).to include('data-custom-emoji-text')
      expect(response.body).to include('Work :fedibird:')
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
