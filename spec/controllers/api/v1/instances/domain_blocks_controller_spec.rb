# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Instances::DomainBlocksController, type: :controller do
  render_views

  around do |example|
    original_show = Setting.show_domain_blocks
    original_rationale = Setting.show_domain_blocks_rationale
    example.run
  ensure
    Setting.show_domain_blocks = original_show
    Setting.show_domain_blocks_rationale = original_rationale
  end

  let(:block) do
    Fabricate(:domain_block, domain: 'blocked.example', severity: :silence, public_comment: 'Reason')
  end

  describe 'GET #index' do
    before { block }

    context 'when show_domain_blocks is all' do
      before { Setting.show_domain_blocks = 'all' }

      it 'returns public domain blocks without authentication' do
        get :index
        entry = body_as_json.first

        expect(response).to have_http_status(200)
        expect(entry[:domain]).to eq(block.public_domain)
        expect(entry[:digest]).to eq(block.domain_digest)
        expect(entry[:severity]).to eq('silence')
      end

      it 'uses the obfuscated public domain' do
        block.update!(obfuscate: true)
        get :index
        entry = body_as_json.first

        expect(entry[:domain]).to eq(block.public_domain)
        expect(entry[:domain]).not_to eq(block.domain)
        expect(entry[:digest]).to eq(block.domain_digest)
      end

      it 'excludes noop media-only domain blocks' do
        Fabricate(:domain_block, domain: 'media-only.example', severity: :noop, reject_media: true)
        get :index

        expect(body_as_json.map { |entry| entry[:severity] }).not_to include('noop')
      end
    end

    context 'when show_domain_blocks is disabled' do
      before { Setting.show_domain_blocks = 'disabled' }

      it 'returns http not found' do
        get :index
        expect(response).to have_http_status(404)
      end
    end

    context 'when show_domain_blocks is users' do
      before { Setting.show_domain_blocks = 'users' }

      it 'returns http not found without a token' do
        get :index
        expect(response).to have_http_status(404)
      end

      it 'returns http success for a valid OAuth user' do
        authenticate_as(Fabricate(:user))
        get :index
        expect(response).to have_http_status(200)
      end
    end
  end

  describe 'GET #index user eligibility' do
    before do
      block
      Setting.show_domain_blocks = 'users'
    end

    it 'returns http not found for an unapproved user' do
      authenticate_as(Fabricate(:user, approved: false))
      get :index
      expect(response).to have_http_status(404)
    end

    it 'returns http not found for an unconfirmed user' do
      authenticate_as(Fabricate(:user, confirmed_at: nil))
      get :index
      expect(response).to have_http_status(404)
    end

    it 'returns http not found for a disabled user' do
      authenticate_as(Fabricate(:user, disabled: true))
      get :index
      expect(response).to have_http_status(404)
    end

    it 'returns http success for a moved user' do
      user = Fabricate(:user)
      user.account.update!(moved_to_account: Fabricate(:account))
      authenticate_as(user)
      get :index
      expect(response).to have_http_status(200)
    end

    it 'returns http forbidden for a suspended user' do
      user = Fabricate(:user)
      user.account.suspend!
      authenticate_as(user)
      get :index
      expect(response).to have_http_status(403)
    end
  end

  describe 'GET #index rationale' do
    before do
      block
      Setting.show_domain_blocks = 'all'
    end

    it 'includes the public comment when rationale is all' do
      Setting.show_domain_blocks_rationale = 'all'
      get :index
      expect(body_as_json.first[:comment]).to eq('Reason')
    end

    it 'hides the comment from unauthenticated users when rationale is users' do
      Setting.show_domain_blocks_rationale = 'users'
      get :index
      expect(body_as_json.first).to include(comment: nil)
    end

    it 'includes the comment for a valid OAuth user when rationale is users' do
      Setting.show_domain_blocks_rationale = 'users'
      authenticate_as(Fabricate(:user))
      get :index
      expect(body_as_json.first[:comment]).to eq('Reason')
    end

    it 'hides the comment when rationale is disabled' do
      Setting.show_domain_blocks_rationale = 'disabled'
      get :index
      expect(body_as_json.first).to include(comment: nil)
    end
  end

  def authenticate_as(user)
    token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read')
    allow(controller).to receive(:doorkeeper_token).and_return(token)
  end
end
