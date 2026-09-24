require 'rails_helper'

RSpec.describe Api::V1::Admin::DomainBlocksController, type: :controller do
  render_views

  let(:role)   { 'admin' }
  let(:user)   { user_with_legacy_role_name(role, account: Fabricate(:account, username: 'alice')) }
  let(:scopes) { 'admin:read admin:write' }
  let(:token)  { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  shared_examples 'forbidden for wrong scope' do |wrong_scope|
    let(:scopes) { wrong_scope }

    it 'returns http forbidden' do
      expect(response).to have_http_status(403)
    end
  end

  shared_examples 'forbidden for wrong role' do |wrong_role|
    let(:role) { wrong_role }

    it 'returns http forbidden' do
      expect(response).to have_http_status(403)
    end
  end

  describe 'GET #index' do
    context 'with no domain blocks' do
      before do
        get :index, format: :json
      end

      it_behaves_like 'forbidden for wrong scope', 'write:statuses'
      it_behaves_like 'forbidden for wrong role', 'user'
      it_behaves_like 'forbidden for wrong role', 'moderator'

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'returns an empty array' do
        expect(body_as_json).to eq([])
      end
    end

    context 'with admin:read scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http success' do
        get :index, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with admin:read:domain_blocks scope' do
      let(:scopes) { 'admin:read:domain_blocks' }

      it 'returns http success' do
        get :index, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'without a token' do
      let(:token) { nil }

      it 'returns http unauthorized' do
        get :index, format: :json
        expect(response).to have_http_status(401)
      end
    end

    context 'when the admin is disabled' do
      before { user.disable! }

      it 'returns http forbidden' do
        get :index, format: :json
        expect(response).to have_http_status(403)
      end
    end

    context 'with domain blocks' do
      let!(:older_block) { Fabricate(:domain_block, domain: 'older.example', severity: :silence, created_at: 2.days.ago) }
      let!(:newer_block) { Fabricate(:domain_block, domain: 'newer.example', severity: :suspend, created_at: 1.day.ago) }

      it 'returns serialized domain blocks newest first' do
        get :index, format: :json

        expect(response).to have_http_status(200)
        expect(body_as_json.size).to eq(2)
        expect(body_as_json.map { |entry| entry[:id] }).to eq([newer_block.id.to_s, older_block.id.to_s])
        expect(body_as_json.first[:id]).to be_a(String)
        expect(body_as_json.first).to include(
          domain: newer_block.domain,
          digest: Digest::SHA256.hexdigest(newer_block.domain),
          severity: 'suspend',
          reject_media: false,
          reject_reports: false,
          obfuscate: false
        )
        expect(body_as_json.second[:digest]).to eq(older_block.domain_digest)
        expect(body_as_json.first).to have_key(:created_at)
        expect(body_as_json.first).to have_key(:private_comment)
        expect(body_as_json.first).to have_key(:public_comment)
      end

      it 'respects the limit parameter' do
        get :index, params: { limit: 1 }, format: :json

        expect(body_as_json.size).to eq(1)
        expect(body_as_json.first[:id]).to eq(newer_block.id.to_s)
      end

      it 'sets pagination Link headers' do
        get :index, params: { limit: 1 }, format: :json

        expect(response.headers['Link'].find_link(['rel', 'next']).href).to eq api_v1_admin_domain_blocks_url(limit: 1, max_id: newer_block.id)
        expect(response.headers['Link'].find_link(['rel', 'prev']).href).to eq api_v1_admin_domain_blocks_url(limit: 1, min_id: newer_block.id)
      end
    end
  end

  describe 'GET #show' do
    let!(:domain_block) do
      Fabricate(:domain_block, domain: 'blocked.example', severity: :silence, reject_media: true, private_comment: 'priv', public_comment: 'pub', obfuscate: true)
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { get :show, params: { id: domain_block.id }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { get :show, params: { id: domain_block.id }, format: :json }
    end

    it 'returns the serialized domain block' do
      get :show, params: { id: domain_block.id }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        id: domain_block.id.to_s,
        domain: 'blocked.example',
        digest: Digest::SHA256.hexdigest('blocked.example'),
        severity: 'silence',
        reject_media: true,
        reject_reports: false,
        private_comment: 'priv',
        public_comment: 'pub',
        obfuscate: true
      )
      expect(body_as_json[:id]).to be_a(String)
      expect(body_as_json[:created_at]).to be_present
    end

    context 'with admin:read:domain_blocks scope' do
      let(:scopes) { 'admin:read:domain_blocks' }

      it 'returns http success' do
        get :show, params: { id: domain_block.id }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    it 'returns http not found for a missing record' do
      get :show, params: { id: -1 }, format: :json
      expect(response).to have_http_status(404)
    end
  end

  describe 'POST #create' do
    let(:params) { { domain: 'foo.bar.com', severity: 'silence' } }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { post :create, params: params, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'user' do
      before { post :create, params: params, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { post :create, params: params, format: :json }
    end

    it 'creates a domain block and logs the action' do
      expect(DomainBlockWorker).to receive(:perform_async)
      expect { post :create, params: params, format: :json }.to change(DomainBlock, :count).by(1).and change(Admin::ActionLog, :count).by(1)
      expect(response).to have_http_status(200)
      expect(body_as_json[:domain]).to eq('foo.bar.com')
      expect(body_as_json[:digest]).to eq(Digest::SHA256.hexdigest('foo.bar.com'))
      expect(body_as_json[:severity]).to eq('silence')
      expect(body_as_json[:id]).to be_a(String)
      expect(Admin::ActionLog.last.action).to eq(:create)
    end

    context 'with admin:write scope' do
      let(:scopes) { 'admin:write' }

      it 'returns http success' do
        allow(DomainBlockWorker).to receive(:perform_async)
        post :create, params: params, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with admin:write:domain_blocks scope' do
      let(:scopes) { 'admin:write:domain_blocks' }

      it 'returns http success' do
        allow(DomainBlockWorker).to receive(:perform_async)
        post :create, params: params, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        post :create, params: params, format: :json
        expect(response).to have_http_status(403)
      end
    end

    it 'serializes the default severity when omitted' do
      allow(DomainBlockWorker).to receive(:perform_async)
      post :create, params: { domain: 'default.example' }, format: :json
      expect(body_as_json[:severity]).to eq('silence')
    end

    it 'returns 422 when domain is missing' do
      post :create, params: {}, format: :json
      expect(response).to have_http_status(422)
    end

    it 'returns 422 when domain is blank' do
      post :create, params: { domain: '' }, format: :json
      expect(response).to have_http_status(422)
    end

    it 'returns 422 when domain is malformed' do
      post :create, params: { domain: 'foo bar' }, format: :json
      expect(response).to have_http_status(422)
    end

    context 'when the domain is already blocked' do
      let!(:existing) { Fabricate(:domain_block, domain: 'foo.bar.com', severity: :silence) }

      it 'returns 422 with the existing domain block and does not duplicate' do
        expect(DomainBlockWorker).not_to receive(:perform_async)
        expect { post :create, params: { domain: 'foo.bar.com', severity: 'suspend' }, format: :json }
          .to_not change(DomainBlock, :count)
        expect { post :create, params: { domain: 'foo.bar.com', severity: 'suspend' }, format: :json }
          .to_not change(Admin::ActionLog, :count)
        expect(response).to have_http_status(422)
        expect(body_as_json[:error]).to be_present
        expect(body_as_json[:existing_domain_block][:id]).to eq(existing.id.to_s)
        expect(body_as_json[:existing_domain_block][:domain]).to eq('foo.bar.com')
        expect(body_as_json[:existing_domain_block][:digest]).to eq(Digest::SHA256.hexdigest('foo.bar.com'))
      end
    end

    context 'when a looser parent-domain rule already exists' do
      let!(:existing) { Fabricate(:domain_block, domain: 'bar.com', severity: :silence) }

      it 'creates the stricter subdomain block' do
        expect(DomainBlockWorker).to receive(:perform_async).once
        expect { post :create, params: { domain: 'foo.bar.com', severity: 'suspend' }, format: :json }
          .to change(DomainBlock, :count).by(1)
          .and change(Admin::ActionLog, :count).by(1)

        expect(response).to have_http_status(200)
        expect(body_as_json[:domain]).to eq('foo.bar.com')
        expect(body_as_json[:severity]).to eq('suspend')
        expect(DomainBlock.find_by(domain: 'foo.bar.com')).to be_suspend
        expect(Admin::ActionLog.last.action).to eq(:create)
        expect(existing.reload.domain).to eq('bar.com')
      end
    end

    context 'when a stricter parent-domain rule already exists' do
      let!(:existing) { Fabricate(:domain_block, domain: 'bar.com', severity: :suspend) }

      it 'returns 422 with the parent domain block and does not enqueue work' do
        expect(DomainBlockWorker).not_to receive(:perform_async)
        expect { post :create, params: { domain: 'foo.bar.com', severity: 'silence' }, format: :json }
          .to_not change(DomainBlock, :count)
        expect { post :create, params: { domain: 'foo.bar.com', severity: 'silence' }, format: :json }
          .to_not change(Admin::ActionLog, :count)
        expect(response).to have_http_status(422)
        expect(body_as_json[:existing_domain_block][:id]).to eq(existing.id.to_s)
        expect(body_as_json[:existing_domain_block][:domain]).to eq('bar.com')
        expect(body_as_json[:existing_domain_block][:digest]).to eq(existing.domain_digest)
      end
    end
  end

  describe 'PUT/PATCH #update' do
    let!(:domain_block) { Fabricate(:domain_block, domain: 'edit.example', severity: :silence) }

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { put :update, params: { id: domain_block.id, severity: 'suspend' }, format: :json }
    end

    it 'updates via PUT and logs the action' do
      expect(DomainBlockWorker).to receive(:perform_async).with(domain_block.id, true)
      expect { put :update, params: { id: domain_block.id, severity: 'suspend', public_comment: 'note' }, format: :json }.to change(Admin::ActionLog, :count).by(1)
      expect(response).to have_http_status(200)
      expect(body_as_json[:severity]).to eq('suspend')
      expect(body_as_json[:public_comment]).to eq('note')
      expect(domain_block.reload.severity).to eq('suspend')
      expect(Admin::ActionLog.last.action).to eq(:update)
    end

    it 'updates via PATCH' do
      allow(DomainBlockWorker).to receive(:perform_async)
      patch :update, params: { id: domain_block.id, reject_reports: true }, format: :json
      expect(response).to have_http_status(200)
      expect(domain_block.reload.reject_reports).to be true
    end

    it 'does not change the domain' do
      allow(DomainBlockWorker).to receive(:perform_async)
      put :update, params: { id: domain_block.id, domain: 'other.example', severity: 'silence' }, format: :json
      expect(domain_block.reload.domain).to eq('edit.example')
    end

    it 'invokes the worker without a severity change flag when severity is unchanged' do
      expect(DomainBlockWorker).to receive(:perform_async).with(domain_block.id, false)
      put :update, params: { id: domain_block.id, public_comment: 'same severity' }, format: :json
    end

    it 'returns http not found for a missing record' do
      put :update, params: { id: -1, severity: 'suspend' }, format: :json
      expect(response).to have_http_status(404)
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        put :update, params: { id: domain_block.id, severity: 'suspend' }, format: :json
        expect(response).to have_http_status(403)
      end
    end
  end

  describe 'severity transitions' do
    let!(:remote_account) { Fabricate(:account, username: 'badguy', domain: 'evil.org') }

    it 'undoes suspension and applies hard silence when changing suspend to silence' do
      domain_block = DomainBlock.create!(domain: 'evil.org', severity: :suspend)
      BlockDomainService.new.call(domain_block)
      expect(remote_account.reload.suspended?).to be true

      put :update, params: { id: domain_block.id, severity: 'silence' }, format: :json

      expect(response).to have_http_status(200)
      expect(domain_block.reload.silence?).to be true
      remote_account.reload
      expect(remote_account.suspended?).to be false
      expect(remote_account.silenced?).to be true
      expect(remote_account.hard_silenced?).to be true
    end

    it 'undoes silence and applies suspension when changing silence to suspend' do
      domain_block = DomainBlock.create!(domain: 'evil.org', severity: :silence)
      BlockDomainService.new.call(domain_block)
      expect(remote_account.reload.silenced?).to be true
      expect(remote_account.hard_silenced?).to be true

      put :update, params: { id: domain_block.id, severity: 'suspend' }, format: :json

      expect(response).to have_http_status(200)
      expect(domain_block.reload.suspend?).to be true
      remote_account.reload
      expect(remote_account.silenced?).to be false
      expect(remote_account.suspended?).to be true
    end
  end

  describe 'DELETE #destroy' do
    let!(:domain_block) { Fabricate(:domain_block) }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { delete :destroy, params: { id: domain_block.id }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { delete :destroy, params: { id: domain_block.id }, format: :json }
    end

    it 'returns empty JSON, removes the domain block, and logs destroy' do
      expect { delete :destroy, params: { id: domain_block.id }, format: :json }.to change(DomainBlock, :count).by(-1).and change(Admin::ActionLog, :count).by(1)
      expect(response).to have_http_status(200)
      expect(body_as_json).to eq({})
      expect(DomainBlock.find_by(id: domain_block.id)).to be_nil
      expect(Admin::ActionLog.last.action).to eq(:destroy)
    end

    it 'uses UnblockDomainService' do
      service = instance_double(UnblockDomainService, call: true)
      allow(UnblockDomainService).to receive(:new).and_return(service)

      delete :destroy, params: { id: domain_block.id }, format: :json

      expect(service).to have_received(:call).with(domain_block)
    end

    it 'returns http not found for a missing record' do
      delete :destroy, params: { id: -1 }, format: :json
      expect(response).to have_http_status(404)
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        delete :destroy, params: { id: domain_block.id }, format: :json
        expect(response).to have_http_status(403)
      end
    end
  end

  describe 'disabled admin' do
    before { user.disable! }

    it 'forbids index with a valid admin token' do
      get :index, format: :json
      expect(response).to have_http_status(403)
    end

    it 'forbids create with a valid admin token' do
      post :create, params: { domain: 'disabled.example' }, format: :json
      expect(response).to have_http_status(403)
    end
  end
end
