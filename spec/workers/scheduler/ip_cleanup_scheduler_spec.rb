# frozen_string_literal: true

require 'rails_helper'

describe Scheduler::IpCleanupScheduler do
  subject { described_class.new }

  it 'clears last_used_ip on tokens older than the retention period and keeps last_used_at' do
    user = Fabricate(:user)
    used_at = 18.months.ago
    old_token = Fabricate(
      :accessible_access_token,
      resource_owner_id: user.id,
      scopes: 'read',
      last_used_at: used_at,
      last_used_ip: '203.0.113.10'
    )
    recent_token = Fabricate(
      :accessible_access_token,
      resource_owner_id: user.id,
      scopes: 'read',
      last_used_at: 1.month.ago,
      last_used_ip: '198.51.100.20'
    )

    subject.perform

    old_token.reload
    recent_token.reload

    expect(old_token.last_used_ip).to be_nil
    expect(old_token.last_used_at).to be_within(1.second).of(used_at)
    expect(recent_token.last_used_ip).to eq(IPAddr.new('198.51.100.20'))
  end
end
