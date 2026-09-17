# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Filters::StatusesController do
  render_views

  before do
    stub_webpacker_manifest
  end

  describe 'GET #index' do
    let(:user) { Fabricate(:user) }
    let(:filter) { Fabricate(:custom_filter, account: user.account) }

    context 'with signed out user' do
      it 'redirects' do
        get :index, params: { filter_id: filter }

        expect(response).to be_redirect
      end
    end

    context 'with a signed in user' do
      context 'with the filter user signed in' do
        before do
          sign_in(user)
          get :index, params: { filter_id: filter }
        end

        it 'returns http success' do
          expect(response).to have_http_status(200)
        end

        it 'returns private cache control headers' do
          expect(response.headers['Cache-Control']).to include('private, no-store')
        end
      end

      context 'with an attached status' do
        let(:status) { Fabricate(:status, account: filter.account, text: 'individually filtered post') }
        let!(:status_filter) { Fabricate(:custom_filter_status, custom_filter: filter, status: status) }

        before do
          sign_in(user)
        end

        it 'lists the filtered status without raising Admin::StatusFilter' do
          get :index, params: { filter_id: filter }

          expect(response).to have_http_status(200)
          expect(response.body).to include('individually filtered post')
          expect(response.body).to include(I18n.t('filters.statuses.index.title'))
          expect(response.body).to include(I18n.t('filters.statuses.batch.remove'))
        end

        it 'renders Japanese copy for the individual posts UI' do
          user.update!(locale: 'ja')
          get :index, params: { filter_id: filter }

          expect(response).to have_http_status(200)
          expect(response.body).to include('フィルターされた投稿')
          expect(response.body).to include('フィルタに戻る')
          expect(response.body).to include('フィルターから削除する')
          expect(response.body).not_to include('translation missing')
        end
      end

      context 'with Fedibird-specific visibilities' do
        let!(:limited_status) { Fabricate(:status, account: filter.account, visibility: :limited, text: 'limited filtered post') }
        let!(:mutual_status) { Fabricate(:status, account: filter.account, visibility: :mutual, text: 'mutual filtered post') }
        let!(:personal_status) { Fabricate(:status, account: filter.account, visibility: :personal, text: 'personal filtered post') }

        before do
          Fabricate(:custom_filter_status, custom_filter: filter, status: limited_status)
          Fabricate(:custom_filter_status, custom_filter: filter, status: mutual_status)
          Fabricate(:custom_filter_status, custom_filter: filter, status: personal_status)
          sign_in(user)
          get :index, params: { filter_id: filter }
        end

        it 'lists limited, mutual, and personal posts with Fedibird visibility icons' do
          expect(response).to have_http_status(200)
          expect(response.body).not_to include('translation missing')

          expect(response.body).to include('limited filtered post')
          expect(response.body).to include(I18n.t('statuses.visibilities.limited'))
          expect(response.body).to include('fa-user-circle')

          expect(response.body).to include('mutual filtered post')
          expect(response.body).to include(I18n.t('statuses.visibilities.mutual'))
          expect(response.body).to include('fa-exchange')

          expect(response.body).to include('personal filtered post')
          expect(response.body).to include(I18n.t('statuses.visibilities.personal'))
          expect(response.body).to include('fa-book')
        end
      end

      context 'with another user signed in' do
        before do
          sign_in(Fabricate(:user))
          get :index, params: { filter_id: filter }
        end

        it 'returns http not found' do
          expect(response).to have_http_status(404)
        end
      end
    end
  end

  describe 'POST #batch' do
    let(:user) { Fabricate(:user) }
    let(:filter) { Fabricate(:custom_filter, account: user.account) }
    let(:status) { Fabricate(:status, account: user.account) }
    let!(:status_filter) { Fabricate(:custom_filter_status, custom_filter: filter, status: status) }

    before do
      sign_in(user)
    end

    it 'removes the selected CustomFilterStatus' do
      post :batch, params: {
        filter_id: filter,
        remove: '',
        form_status_filter_batch_action: { status_filter_ids: [status_filter.id] },
      }

      expect(CustomFilterStatus.exists?(status_filter.id)).to be false
      expect(response).to redirect_to(edit_filter_path(filter))
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
