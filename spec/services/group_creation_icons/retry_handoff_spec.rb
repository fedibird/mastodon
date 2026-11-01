# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupCreationIcons::RetryHandoff do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  around do |example|
    previous = Setting.group_creation_requests
    Setting.group_creation_requests = true
    example.run
  ensure
    Setting.group_creation_requests = previous
  end

  let(:reviewer) { user_with_role('Owner') }
  let(:request) do
    GroupCreationRequest.create!(
      requester_account: Fabricate(:user).account,
      username: 'retryonly',
      display_name: 'Retry',
      note: 'retry'
    )
  end

  it 'does not resume a pending request or accept a moderator' do
    expect(described_class.call(request: request, actor_account: reviewer.account)).to eq :not_retryable
    expect(described_class.call(request: request, actor_account: user_with_role('Moderator').account)).to eq :not_authorized
    expect(request.reload).to be_pending
  end
end
