# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::ReportsController, type: :controller do
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'POST #create' do
    let(:scopes)  { 'write:reports' }
    let!(:status) { Fabricate(:status) }
    let!(:admin)  { Fabricate(:user, admin: true) }

    before do
      allow(AdminMailer).to receive(:new_report).and_return(double('email', deliver_later: nil))
    end

    context 'with default params' do
      before do
        post :create, params: { status_ids: [status.id], account_id: status.account.id, comment: 'reasons' }
      end

      it 'creates a report' do
        expect(status.reload.account.targeted_reports).not_to be_empty
        expect(response).to have_http_status(200)
      end

      it 'defaults to the other category without rule ids' do
        report = status.account.targeted_reports.last

        expect(report).to be_other
        expect(report.rule_ids).to be_blank
      end

      it 'sends e-mails to admins' do
        expect(AdminMailer).to have_received(:new_report).with(admin.account, Report)
      end
    end

    context 'with spam category' do
      it 'creates a spam report' do
        post :create, params: { status_ids: [status.id], account_id: status.account.id, category: 'spam' }

        expect(response).to have_http_status(200)
        expect(status.account.targeted_reports.last).to be_spam
      end
    end

    context 'with legal category' do
      it 'creates a legal report without rule ids' do
        post :create, params: {
          account_id: status.account.id,
          status_ids: [status.id],
          category: 'legal',
          comment: 'legal reason',
        }

        report = status.account.targeted_reports.last

        expect(response).to have_http_status(200)
        expect(report).to be_legal
        expect(report.rule_ids).to be_blank
      end
    end

    context 'with legal category and rule ids' do
      let!(:rule) { Fabricate(:rule, deleted_at: nil, priority: 0) }

      it 'forces the category to violation' do
        post :create, params: {
          account_id: status.account.id,
          category: 'legal',
          rule_ids: [rule.id],
        }

        report = status.account.targeted_reports.last

        expect(response).to have_http_status(200)
        expect(report).to be_violation
        expect(report).to_not be_legal
        expect(report.rule_ids).to eq [rule.id]
      end
    end

    context 'with violation and a valid rule' do
      let!(:rule) { Fabricate(:rule, deleted_at: nil, priority: 0) }

      it 'creates a violation report with those rule ids' do
        post :create, params: {
          status_ids: [status.id],
          account_id: status.account.id,
          category: 'violation',
          rule_ids: [rule.id],
        }

        report = status.account.targeted_reports.last

        expect(response).to have_http_status(200)
        expect(report).to be_violation
        expect(report.rule_ids).to eq [rule.id]
      end
    end

    context 'with rule ids and a non-violation category' do
      let!(:rule) { Fabricate(:rule, deleted_at: nil, priority: 0) }

      it 'forces the category to violation' do
        post :create, params: {
          status_ids: [status.id],
          account_id: status.account.id,
          category: 'spam',
          rule_ids: [rule.id],
        }

        report = status.account.targeted_reports.last

        expect(response).to have_http_status(200)
        expect(report).to be_violation
        expect(report).to_not be_spam
        expect(report.rule_ids).to eq [rule.id]
      end
    end

    context 'with violation and a nonexistent rule' do
      it 'does not create a report' do
        expect do
          post :create, params: {
            status_ids: [status.id],
            account_id: status.account.id,
            category: 'violation',
            rule_ids: [-1],
          }
        end.to_not change(Report, :count)

        expect(response).to have_http_status(422)
      end
    end

    context 'with violation and no rules' do
      it 'does not create a report' do
        expect do
          post :create, params: {
            status_ids: [status.id],
            account_id: status.account.id,
            category: 'violation',
          }
        end.to_not change(Report, :count)

        expect(response).to have_http_status(422)
      end
    end

    context 'with a status that does not belong to the reported account' do
      let!(:other_status) { Fabricate(:status) }

      it 'does not create a report' do
        expect do
          post :create, params: {
            status_ids: [other_status.id],
            account_id: status.account.id,
            comment: 'reasons',
            category: 'spam',
          }
        end.to_not change(Report, :count)

        expect(response).to have_http_status(404)
      end
    end

    context 'with forward_to_domains targeting a replied-to server' do
      let(:remote_account) { Fabricate(:account, domain: 'example.com', protocol: :activitypub, inbox_url: 'http://example.com/inbox') }
      let(:remote_thread_account) { Fabricate(:account, domain: 'foo.com', protocol: :activitypub, inbox_url: 'http://foo.com/inbox') }
      let!(:reported_status) { Fabricate(:status, account: remote_account, thread: Fabricate(:status, account: remote_thread_account)) }

      before do
        stub_request(:post, 'http://example.com/inbox').to_return(status: 200)
        stub_request(:post, 'http://foo.com/inbox').to_return(status: 200)
      end

      it 'forwards only to the selected domain' do
        post :create, params: {
          account_id: remote_account.id,
          status_ids: [reported_status.id],
          comment: 'reasons',
          forward: true,
          forward_to_domains: ['foo.com'],
        }

        expect(response).to have_http_status(200)
        expect(a_request(:post, 'http://example.com/inbox')).to_not have_been_made
        expect(a_request(:post, 'http://foo.com/inbox')).to have_been_made.once
        expect(remote_account.targeted_reports.last.forwarded).to be false
      end
    end
  end
end
