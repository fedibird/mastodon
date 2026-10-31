# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Group creation request CSRF' do
  before do
    https!
    stub_webpacker_manifest
    Setting.group_creation_requests = true
  end

  around do |example|
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    Dir.mktmpdir do |dir|
      ClimateControl.modify(GROUP_CREATION_ICON_ROOT: dir, GROUP_CREATION_ICON_STORAGE: 'filesystem', LOCAL_HTTPS: nil) do
        example.run
      end
    end
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  let(:user) { Fabricate(:user) }

  it 'does not create or cancel a request when the CSRF token is missing' do
    sign_in user, scope: :user
    request = GroupCreationRequest.create!(
      requester_account: user.account,
      username: 'csrfgroup',
      display_name: 'CSRF',
      note: 'pending'
    )

    expect do
      post confirm_settings_group_creation_requests_path, params: {
        group_creation_request: { username: 'another', display_name: 'Another', note: 'no token' },
      }
    end.not_to change(GroupCreationRequest, :count)
    expect(response).to have_http_status(:unprocessable_entity)

    expect do
      post cancel_settings_group_creation_request_path(request), params: { lock_version: request.lock_version }
    end.not_to(change { request.reload.state })
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
