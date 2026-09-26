# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::StatusSerializer do
  def serialize_status(status, user)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        status,
        serializer: described_class,
        scope: user,
        scope_name: :current_user
      ).to_json,
      symbolize_names: true
    )
  end

  def status_for(website)
    user = Fabricate(:user)
    application = Fabricate(:application)
    application.update_column(:website, website)
    status = Fabricate(:status, account: user.account, application: application)

    [status, user]
  end

  it 'renders a blank application website as null' do
    status, user = status_for('')
    json = serialize_status(status, user)

    expect(json[:application]).to include(name: 'Example', website: nil)
    expect(json[:application]).to have_key(:website)
  end

  it 'renders a nil application website as null' do
    status, user = status_for(nil)
    json = serialize_status(status, user)

    expect(json[:application]).to include(name: 'Example', website: nil)
    expect(json[:application]).to have_key(:website)
  end

  it 'keeps a populated application website' do
    status, user = status_for('https://example.com')
    json = serialize_status(status, user)

    expect(json.dig(:application, :name)).to eq('Example')
    expect(json.dig(:application, :website)).to eq('https://example.com')
  end
end

RSpec.describe REST::ApplicationSerializer do
  def serialize_application(application)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        application,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  it 'already renders a blank website as null' do
    application = Fabricate(:application)
    application.update_column(:website, '')

    expect(serialize_application(application)[:website]).to be_nil
  end

  it 'keeps a populated website' do
    application = Fabricate(:application, website: 'https://example.com')

    expect(serialize_application(application)[:website]).to eq('https://example.com')
  end
end
