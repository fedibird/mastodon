# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::AccountSubscribesController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:subscription) { Fabricate(:account_subscribe, account: user.account) }

  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
  end

  describe 'GET #index' do
    it 'keeps the page in the edit and delete links' do
      subscription
      get :index, params: { page: 1 }

      doc = Nokogiri::HTML(response.body)
      edit_link = doc.at_css("a[href='#{edit_settings_account_subscribe_path(subscription, page: 1)}']")
      delete_link = doc.at_css("a[href='#{settings_account_subscribe_path(subscription, page: 1)}']")

      expect(edit_link).to be_present
      expect(delete_link).to be_present
      expect(delete_link['data-method']).to eq('delete')
    end
  end

  describe 'GET #edit' do
    it 'keeps the return page in the update form action' do
      get :edit, params: { id: subscription.id, page: 3 }

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("form[action='#{settings_account_subscribe_path(subscription, page: 3)}']")).to be_present
    end
  end

  describe 'PUT #update' do
    it 'redirects to the original page after a successful update' do
      put :update, params: { id: subscription.id, page: 3, form_account_subscribe: { show_reblogs: '0' } }

      expect(response).to redirect_to(settings_account_subscribes_path(page: 3))
      expect(subscription.reload.show_reblogs).to be false
    end

    it 'retains the existing default redirect without a page parameter' do
      put :update, params: { id: subscription.id, form_account_subscribe: { show_reblogs: '0' } }

      expect(response).to redirect_to(settings_account_subscribes_path)
    end
  end

  describe 'DELETE #destroy' do
    let(:remaining_count) { 81 }
    let(:unsubscribe_service) { instance_double(UnsubscribeAccountService) }

    before do
      allow(controller).to receive(:current_account).and_return(user.account)
      allow(user.account.active_subscribes).to receive(:count).and_return(remaining_count)
      allow(UnsubscribeAccountService).to receive(:new).and_return(unsubscribe_service)
      allow(unsubscribe_service).to receive(:call) { subscription.destroy! }
    end

    it 'redirects to the original page if it still exists' do
      delete :destroy, params: { id: subscription.id, page: 3 }

      expect(response).to redirect_to(settings_account_subscribes_path(page: 3))
    end

    context 'when deleting the last entry on the original page' do
      let(:remaining_count) { 80 }

      it 'redirects to the preceding valid page' do
        delete :destroy, params: { id: subscription.id, page: 3 }

        expect(response).to redirect_to(settings_account_subscribes_path(page: 2))
      end
    end

    context 'when there is no second page left' do
      let(:remaining_count) { 40 }

      it 'redirects to the first page' do
        delete :destroy, params: { id: subscription.id, page: 2 }

        expect(response).to redirect_to(settings_account_subscribes_path)
      end
    end

    it 'retains the existing default redirect without a page parameter' do
      delete :destroy, params: { id: subscription.id }

      expect(response).to redirect_to(settings_account_subscribes_path)
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
