# frozen_string_literal: true

require 'rails_helper'

describe Admin::RulesController do
  render_views

  let(:user) { user_with_role('Owner') }

  before do
    stub_webpacker_manifest
    sign_in user, scope: :user
  end

  describe 'GET #index' do
    it 'renders the hint field' do
      get :index

      expect(response).to have_http_status(:success)
      expect(response.body).to include('name="rule[hint]"')
      expect(response.body).to include('Additional information')
      expect(response.body).to include('Optional. Provide more details about the rule')
      expect(response.body).not_to include('translation missing')
    end
  end

  describe 'GET #edit' do
    let(:rule) { Rule.create!(text: 'Be kind', hint: 'Explain kindness') }

    it 'renders the current hint' do
      get :edit, params: { id: rule.id }

      expect(response).to have_http_status(:success)
      expect(response).to render_template(:edit)
      expect(response.body).to include('name="rule[hint]"')
      expect(response.body).to include('Explain kindness')
    end
  end

  describe 'POST #create' do
    it 'saves text and priority with an empty hint when hint is omitted' do
      expect do
        post :create, params: { rule: { text: 'Be kind', priority: 2 } }
      end.to change(Rule, :count).by(1)

      rule = Rule.order(:id).last
      expect(rule.text).to eq 'Be kind'
      expect(rule.priority).to eq 2
      expect(rule.hint).to eq ''
      expect(response).to redirect_to(admin_rules_path)
    end

    it 'saves a provided hint' do
      post :create, params: { rule: { text: 'No spam', hint: 'No commercial posts', priority: 1 } }

      rule = Rule.order(:id).last
      expect(rule.text).to eq 'No spam'
      expect(rule.hint).to eq 'No commercial posts'
      expect(rule.priority).to eq 1
      expect(response).to redirect_to(admin_rules_path)
    end

    it 'does not create a rule without text' do
      expect do
        post :create, params: { rule: { text: '', hint: 'Unused', priority: 1 } }
      end.to_not change(Rule, :count)

      expect(response).to render_template(:index)
    end
  end

  describe 'PUT #update' do
    let!(:rule) { Rule.create!(text: 'Original', hint: 'Old detail', priority: 1) }

    it 'updates hint along with text and priority' do
      put :update, params: { id: rule.id, rule: { text: 'Updated', hint: 'New detail', priority: 4 } }

      expect(response).to redirect_to(admin_rules_path)
      expect(rule.reload.text).to eq 'Updated'
      expect(rule.hint).to eq 'New detail'
      expect(rule.priority).to eq 4
    end

    it 'updates text and priority without clearing an omitted hint' do
      put :update, params: { id: rule.id, rule: { text: 'Updated text', priority: 3 } }

      expect(rule.reload.text).to eq 'Updated text'
      expect(rule.priority).to eq 3
      expect(rule.hint).to eq 'Old detail'
    end

    it 'does not update a rule with blank text' do
      put :update, params: { id: rule.id, rule: { text: '', hint: 'Ignored', priority: 9 } }

      expect(response).to render_template(:edit)
      expect(rule.reload.text).to eq 'Original'
      expect(rule.hint).to eq 'Old detail'
      expect(rule.priority).to eq 1
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
