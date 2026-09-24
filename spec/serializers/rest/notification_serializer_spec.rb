# frozen_string_literal: true

require 'rails_helper'

describe REST::NotificationSerializer do
  def serialize(notification)
    described_class.new(notification, scope: Fabricate(:user), scope_name: :current_user).as_json
  end

  it 'includes the edited status for update' do
    status = Fabricate(:status, text: 'edited')
    notification = Fabricate(:notification, activity: status, type: :update, from_account: status.account)

    json = serialize(notification)

    expect(json[:type]).to eq :update
    expect(json[:account][:id]).to eq status.account_id.to_s
    expect(json[:status].object.id).to eq status.id
  end

  it 'includes the new account for admin.sign_up' do
    account = Fabricate(:account)
    notification = Fabricate(:notification, activity: account, type: :'admin.sign_up', from_account: account)

    json = serialize(notification)

    expect(json[:type]).to eq :'admin.sign_up'
    expect(json[:account][:id]).to eq account.id.to_s
    expect(json).not_to have_key(:status)
    expect(json).not_to have_key(:report)
  end

  it 'includes the report and its target account for admin.report' do
    report = Fabricate(:report)
    notification = Fabricate(:notification, activity: report, type: :'admin.report', from_account: report.account)

    json = serialize(notification)

    expect(json[:type]).to eq :'admin.report'
    expect(json[:account][:id]).to eq report.account_id.to_s
    expect(json[:report][:id]).to eq report.id.to_s
    expect(json[:report][:target_account][:id]).to eq report.target_account_id.to_s
  end
end
