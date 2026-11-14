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

  def reset_request_body
    controller.instance_variable_set(:@json_body, nil)
  end

  def load_snapshot(name)
    JSON.parse(Rails.root.join('spec/fixtures/post_drafts', "#{name}.json").read)
  end

  describe 'P0 snapshot posts' do
    before { authorize(user) }

    %w(primary hashtag audience long-ja long-en).each do |name|
      it "creates #{name} without publishing it" do
        raw = load_snapshot(name)
        raw['account_id'] = user.account_id.to_s
        statuses = Status.count
        reset_request_body

        post :create, body: { client_uuid: raw['client_draft_uuid'], payload: raw }.to_json, as: :json

        expect(response).to have_http_status(201)
        expect(body_as_json[:media_retained]).to be false
        expect(body_as_json.dig(:payload, :input, :text)).to eq raw['input']['text']
        expect(body_as_json.dig(:payload, :input, :media)).to eq []
        expect(Status.count).to eq statuses
      end
    end
  end
end
