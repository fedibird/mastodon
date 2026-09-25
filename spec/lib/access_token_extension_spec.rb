# frozen_string_literal: true

require 'rails_helper'

describe AccessTokenExtension do
  describe '#update_last_used' do
    let(:token) { Fabricate(:accessible_access_token, resource_owner_id: Fabricate(:user).id, scopes: 'read') }
    let(:request) { instance_double(ActionDispatch::Request, remote_ip: '203.0.113.10') }

    it 'records the current time and remote IP' do
      expect(token.last_used_at).to be_nil
      expect(token.last_used_ip).to be_nil

      token.update_last_used(request)
      token.reload

      expect(token.last_used_at).to be_within(5.seconds).of(Time.now.utc)
      expect(token.last_used_ip).to eq(IPAddr.new('203.0.113.10'))
    end
  end
end
