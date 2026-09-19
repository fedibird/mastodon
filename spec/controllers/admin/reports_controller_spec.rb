require 'rails_helper'

describe Admin::ReportsController do
  render_views

  let(:user) { Fabricate(:user, admin: true) }
  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
  end

  describe 'GET #index' do
    it 'returns http success with no filters' do
      specified = Fabricate(:report, action_taken_at: nil)
      other = Fabricate(:report, action_taken_at: Time.now.utc)

      get :index

      reports = assigns(:reports).to_a
      expect(reports).to include(specified)
      expect(reports).not_to include(other)
      expect(response).to have_http_status(200)
    end

    it 'returns http success with resolved filter' do
      specified = Fabricate(:report, action_taken_at: Time.now.utc)
      other = Fabricate(:report, action_taken_at: nil)

      get :index, params: { resolved: 1 }

      reports = assigns(:reports).to_a
      expect(reports).to include(specified)
      expect(reports).not_to include(other)

      expect(response).to have_http_status(200)
    end
  end

  describe 'GET #show' do
    it 'renders report' do
      report = Fabricate(:report)

      get :show, params: { id: report }

      expect(assigns(:report)).to eq report
      expect(response).to have_http_status(200)
    end
  end

  describe 'POST #resolve' do
    it 'resolves the report' do
      report = Fabricate(:report)

      put :resolve, params: { id: report }
      expect(response).to redirect_to(admin_reports_path)
      report.reload
      expect(report.action_taken_by_account).to eq user.account
      expect(report.action_taken).to eq true
      expect(report.action_taken_at).to be_present
    end

    it 'sets trust level when the report is an antispam one' do
      report = Fabricate(:report, account: Account.representative)

      put :resolve, params: { id: report }
      report.reload
      expect(report.target_account.trust_level).to eq Account::TRUST_LEVELS[:trusted]
    end
  end

  describe 'POST #reopen' do
    it 'reopens the report' do
      report = Fabricate(:report, action_taken_at: Time.now.utc, action_taken_by_account_id: user.account.id)

      put :reopen, params: { id: report }
      expect(response).to redirect_to(admin_report_path(report))
      report.reload
      expect(report.action_taken_by_account).to eq nil
      expect(report.action_taken).to eq false
      expect(report.action_taken_at).to be_nil
    end
  end

  describe 'POST #assign_to_self' do
    it 'reopens the report' do
      report = Fabricate(:report)

      put :assign_to_self, params: { id: report }
      expect(response).to redirect_to(admin_report_path(report))
      report.reload
      expect(report.assigned_account).to eq user.account
    end
  end

  describe 'POST #unassign' do
    it 'reopens the report' do
      report = Fabricate(:report)

      put :unassign, params: { id: report }
      expect(response).to redirect_to(admin_report_path(report))
      report.reload
      expect(report.assigned_account).to eq nil
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
