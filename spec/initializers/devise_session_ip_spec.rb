# frozen_string_literal: true

require 'rails_helper'

describe 'Warden session IP refresh' do
  it 'updates the session activation IP and the user_ips view' do
    user = Fabricate(:user)
    activation = SessionActivation.activate(session_id: SecureRandom.hex(16), user: user, ip: '192.0.2.10')
    signed = { '_session_id' => activation.session_id }
    warden = instance_double(Warden::Proxy, raw_session: {})
    allow(warden).to receive(:cookies).and_return(instance_double(ActionDispatch::Cookies::CookieJar, signed: signed))
    allow(warden).to receive(:request).and_return(instance_double(ActionDispatch::Request, remote_ip: '198.51.100.20'))
    allow(warden).to receive(:logout)

    Warden::Manager._run_callbacks(:after_set_user, user, warden, { event: :fetch })

    expect(activation.reload.ip.to_s).to eq '198.51.100.20'
    expect(user.ips.map { |row| row.ip.to_s }).to include('198.51.100.20')
    expect(user.ips.map { |row| row.ip.to_s }).not_to include('192.0.2.10')
    expect(User.matches_ip('198.51.100.20')).to include(user)
  end
end
