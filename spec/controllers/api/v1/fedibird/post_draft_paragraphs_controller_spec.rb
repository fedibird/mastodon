# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::PostDraftsController, type: :controller do
  render_views

  let(:user) { Fabricate(:user) }

  def authorize(owner)
    controller.instance_variable_set(:@current_user, nil)
    token = Fabricate(:accessible_access_token, resource_owner_id: owner.id, scopes: 'read:post_drafts write:post_drafts')
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  it 'reads a paragraph draft back with the same line breaks' do
    authorize(user)
    raw = JSON.parse(Rails.root.join('spec/fixtures/post_drafts/paragraphs.json').read)
    raw['account_id'] = user.account_id.to_s
    text = "1段落目\n\n2段落目 #test\n@user"
    statuses = Status.count
    expect(raw['input']['text']).to eq text

    post :create, body: { client_uuid: raw['client_draft_uuid'], payload: raw }.to_json, as: :json
    expect(response).to have_http_status(201)
    draft_id = body_as_json[:draft_id]

    controller.instance_variable_set(:@json_body, nil)
    get :show, params: { id: draft_id }

    expect(response).to have_http_status(200)
    expect(body_as_json.dig(:payload, :input, :text)).to eq text
    expect(Status.count).to eq statuses
  end
end
