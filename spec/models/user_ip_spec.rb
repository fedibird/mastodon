# frozen_string_literal: true

require 'rails_helper'

describe UserIp do
  it 'is readonly' do
    expect(described_class.new.readonly?).to be true
  end

  it 'aggregates sign-up, session, and successful login IPs and ignores failed logins' do
    created_at = Time.utc(2026, 9, 1, 8, 0, 0)
    session_at = Time.utc(2026, 9, 2, 8, 0, 0)
    login_at = Time.utc(2026, 9, 3, 8, 0, 0)
    user = Fabricate(:user)
    user.update_columns(sign_up_ip: '192.0.2.10', created_at: created_at)

    activation = SessionActivation.activate(session_id: SecureRandom.hex(16), user: user, ip: '192.0.2.20')
    activation.update_columns(updated_at: session_at)

    LoginActivity.create!(user: user, authentication_method: 'password', success: true, ip: '192.0.2.10', created_at: login_at)
    LoginActivity.create!(user: user, authentication_method: 'password', success: false, ip: '198.51.100.8', created_at: login_at)

    rows = user.ips.index_by { |row| row.ip.to_s }

    expect(rows.keys).to contain_exactly('192.0.2.10', '192.0.2.20')
    expect(rows['192.0.2.10'].used_at).to be_within(1.second).of(login_at)
    expect(rows['192.0.2.20'].used_at).to be_within(1.second).of(session_at)
    expect(rows['192.0.2.10'].used_at).to be > created_at
  end
end
