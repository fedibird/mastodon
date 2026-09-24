# frozen_string_literal: true

require 'rails_helper'

describe REST::Admin::IpSerializer do
  it 'serializes ip and used_at' do
    user = Fabricate(:user)
    user.update_columns(sign_up_ip: '192.0.2.10', created_at: Time.utc(2026, 9, 1, 8, 0, 0))
    record = user.ips.first

    json = JSON.parse(described_class.new(record).to_json)

    expect(json['ip']).to eq '192.0.2.10'
    expect { DateTime.rfc3339(json['used_at']) }.not_to raise_error
  end
end
