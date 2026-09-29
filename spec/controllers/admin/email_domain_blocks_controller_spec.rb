# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::EmailDomainBlocksController, type: :controller do
  render_views

  before do
    stub_webpacker_manifest
    sign_in user_with_role('Owner'), scope: :user
  end

  describe 'GET #index' do
    around do |example|
      default_per_page = EmailDomainBlock.default_per_page
      EmailDomainBlock.paginates_per 1
      example.run
      EmailDomainBlock.paginates_per default_per_page
    end

    it 'renders email blacks' do
      2.times { Fabricate(:email_domain_block) }

      get :index, params: { page: 2 }

      assigned = assigns(:email_domain_blocks)
      expect(assigned.count).to eq 1
      expect(assigned.klass).to be EmailDomainBlock
      expect(response).to have_http_status(200)
    end
  end

  describe 'GET #new' do
    it 'assigns a new email black' do
      get :new

      expect(assigns(:email_domain_block)).to be_instance_of(EmailDomainBlock)
      expect(response).to have_http_status(200)
    end

    it 'renders the approval checkbox and the DNS records checkbox' do
      get :new

      expect(response.body).to include('email_domain_block[allow_with_approval]')
      expect(response.body).to include(I18n.t('admin.email_domain_blocks.allow_registrations_with_approval'))
      expect(response.body).to include('email_domain_block[with_dns_records]')
    end
  end

  describe 'GET #index approval label' do
    it 'shows the approval label only for approval-only blocks' do
      normal   = Fabricate(:email_domain_block, domain: 'blocked.example', allow_with_approval: false)
      approval = Fabricate(:email_domain_block, domain: 'approval.example', allow_with_approval: true)
      child    = Fabricate(:email_domain_block, domain: '203.0.113.10', parent: approval, allow_with_approval: true)

      get :index

      expect(response).to have_http_status(200)
      expect(response.body).to include(normal.domain)
      expect(response.body).to include(approval.domain)
      expect(response.body).to include(child.domain)
      expect(response.body.scan(I18n.t('admin.email_domain_blocks.allow_registrations_with_approval')).size).to eq 2
    end

    it 'does not show the approval label for a normal block' do
      Fabricate(:email_domain_block, domain: 'blocked.example', allow_with_approval: false)

      get :index

      expect(response.body).to include('blocked.example')
      expect(response.body).not_to include(I18n.t('admin.email_domain_blocks.allow_registrations_with_approval'))
    end
  end

  describe 'POST #create' do
    it 'blocks the domain when succeeded to save' do
      post :create, params: { email_domain_block: { domain: 'example.com' } }

      expect(flash[:notice]).to eq I18n.t('admin.email_domain_blocks.created_msg')
      expect(response).to redirect_to(admin_email_domain_blocks_path)
      expect(EmailDomainBlock.find_by(domain: 'example.com').allow_with_approval).to be false
    end

    it 'saves allow_with_approval' do
      post :create, params: { email_domain_block: { domain: 'approval.example', allow_with_approval: '1' } }

      block = EmailDomainBlock.find_by(domain: 'approval.example')
      expect(block.allow_with_approval).to be true
      expect(response).to redirect_to(admin_email_domain_blocks_path)
    end

    it 'copies allow_with_approval onto DNS children of a normal parent' do
      stub_email_domain_dns('blocked.example')

      post :create, params: { email_domain_block: { domain: 'blocked.example', with_dns_records: '1', allow_with_approval: '0' } }

      parent = EmailDomainBlock.find_by(domain: 'blocked.example')
      expect(parent.allow_with_approval).to be false
      expect(parent.children.pluck(:domain)).to contain_exactly('mail.blocked.example', '203.0.113.10', '203.0.113.11')
      expect(parent.children.pluck(:allow_with_approval).uniq).to eq [false]
    end

    it 'copies allow_with_approval onto DNS children of an approval-only parent' do
      stub_email_domain_dns('approval.example')

      post :create, params: { email_domain_block: { domain: 'approval.example', with_dns_records: '1', allow_with_approval: '1' } }

      parent = EmailDomainBlock.find_by(domain: 'approval.example')
      expect(parent.allow_with_approval).to be true
      expect(parent.children.pluck(:domain)).to contain_exactly('mail.approval.example', '203.0.113.10', '203.0.113.11')
      expect(parent.children.pluck(:allow_with_approval).uniq).to eq [true]
    end
  end

  describe 'DELETE #destroy' do
    it 'unblocks the domain' do
      email_domain_block = Fabricate(:email_domain_block)
      delete :destroy, params: { id: email_domain_block.id }

      expect(flash[:notice]).to eq I18n.t('admin.email_domain_blocks.destroyed_msg')
      expect(response).to redirect_to(admin_email_domain_blocks_path)
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  def stub_email_domain_dns(domain)
    resolver = double
    mx_host = "mail.#{domain}"
    allow(resolver).to receive(:timeouts=).and_return(nil)
    allow(Resolv::DNS).to receive(:open).and_yield(resolver)
    allow(resolver).to receive(:getresources).with(domain, Resolv::DNS::Resource::IN::MX).and_return([double(exchange: mx_host)])
    allow(resolver).to receive(:getresources).with(domain, Resolv::DNS::Resource::IN::A).and_return([double(address: '203.0.113.10')])
    allow(resolver).to receive(:getresources).with(domain, Resolv::DNS::Resource::IN::AAAA).and_return([])
    allow(resolver).to receive(:getresources).with(mx_host, Resolv::DNS::Resource::IN::A).and_return([double(address: '203.0.113.11')])
    allow(resolver).to receive(:getresources).with(mx_host, Resolv::DNS::Resource::IN::AAAA).and_return([])
  end
end
