# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Feed route list creation CSRF' do
  let(:user) { Fabricate(:user, password: '123456789') }

  before { stub_webpacker_manifest }

  around do |example|
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  it 'does not create a destination list without the CSRF token' do
    enable_external_bridge_feeds!(user)
    sign_in user, scope: :user

    expect do
      post settings_external_services_feed_route_lists_path, params: { list: { title: 'No token' } }, as: :json
    end.not_to change(List, :count)

    expect(response).to have_http_status(:unprocessable_entity)
  end
end
