# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Statuses::EmojiReactionsController, type: :controller do
  render_views

  let(:user) { Fabricate(:user) }
  let(:author) { Fabricate(:user).account }
  let(:status) { Fabricate(:status, account: author) }

  before do
    allow(controller).to receive(:doorkeeper_token) do
      Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:favourites')
    end
  end

  around { |example| Sidekiq::Testing.fake! { example.run } }

  def react
    put :update, params: { status_id: status.id, id: '👍' }, format: :json
  end

  def unreact
    delete :destroy, params: { status_id: status.id, id: '👍' }, format: :json
  end

  it 'keeps reactions working when at least one picker is enabled' do
    user.settings['emoji_picker_disable_standard'] = true
    react
    expect(response).to have_http_status(200)
    expect(EmojiReaction.where(account: user.account, status_id: status.id).count).to eq 1

    unreact
    expect(response).to have_http_status(200)

    user.settings['emoji_picker_disable_standard'] = false
    user.settings['emoji_picker_disable_personal'] = true
    react
    expect(response).to have_http_status(200)
    expect(EmojiReaction.where(account: user.account, status_id: status.id).count).to eq 1
  end

  it 'denies creating reactions when both pickers are disabled from the first request' do
    # The controller spec reuses a controller object across actions. Set both
    # preferences before the first request so an already memoized current_user
    # cannot mask the setting that the API must enforce.
    user.settings['emoji_picker_disable_standard'] = true
    user.settings['emoji_picker_disable_personal'] = true

    react
    expect(response).to have_http_status(403)
    expect(JSON.parse(response.body)).to eq('error' => 'This action is not allowed')
    expect(EmojiReaction.where(account: user.account, status_id: status.id).count).to eq 0
  end

  it 'allows removing an existing reaction after both pickers are disabled' do
    react
    expect(response).to have_http_status(200)
    expect(EmojiReaction.where(account: user.account, status_id: status.id).count).to eq 1

    user.settings['emoji_picker_disable_standard'] = true
    user.settings['emoji_picker_disable_personal'] = true

    unreact
    expect(response).to have_http_status(200)
    expect(EmojiReaction.where(account: user.account, status_id: status.id).count).to eq 0
  end
end
