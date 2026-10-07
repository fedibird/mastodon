# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::ScheduledStatusSerializer do
  it 'keeps audience_account_id in params and still drops application_id' do
    scheduled = Fabricate(:scheduled_status, params: {
                            'text' => 'Hello',
                            'visibility' => 'public',
                            'audience_account_id' => '456',
                            'application_id' => 99,
                          })
    json = JSON.parse(ActiveModelSerializers::SerializableResource.new(scheduled, serializer: described_class).to_json)

    expect(json['params']['audience_account_id']).to eq '456'
    expect(json['params']['text']).to eq 'Hello'
    expect(json['params']).not_to have_key('application_id')
  end
end
