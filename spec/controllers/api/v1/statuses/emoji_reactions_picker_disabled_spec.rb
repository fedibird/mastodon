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

  it 'allows reactions when only the standard picker is disabled' do
    user.settings['emoji_picker_disable_standard'] = true
    expect(user.reload.setting_emoji_picker_disable_standard).to be true
    expect(user.setting_emoji_picker_disable_personal).to be false

    react
    expect(response).to have_http_status(200)
    expect(EmojiReaction.where(account: user.account, status_id: status.id).count).to eq 1
  end

  it 'allows reactions when only personal sets are disabled' do
    user.settings['emoji_picker_disable_personal'] = true
    expect(user.reload.setting_emoji_picker_disable_personal).to be true
    expect(user.setting_emoji_picker_disable_standard).to be false

    react
    expect(response).to have_http_status(200)
    expect(EmojiReaction.where(account: user.account, status_id: status.id).count).to eq 1
  end

  it 'denies creating reactions when both pickers are disabled' do
    user.settings['emoji_picker_disable_standard'] = true
    user.settings['emoji_picker_disable_personal'] = true
    expect(user.reload.setting_emoji_picker_disable_standard).to be true
    expect(user.setting_emoji_picker_disable_personal).to be true

    react
    expect(response).to have_http_status(403)
    expect(JSON.parse(response.body)).to eq('error' => 'This action is not allowed')
    expect(EmojiReaction.where(account: user.account, status_id: status.id).count).to eq 0
  end

  it 'allows removing an existing reaction while both pickers are disabled' do
    user.settings['emoji_picker_disable_standard'] = true
    user.settings['emoji_picker_disable_personal'] = true
    expect(user.reload.setting_emoji_picker_disable_standard).to be true
    expect(user.setting_emoji_picker_disable_personal).to be true

    # Seed the existing reaction without an earlier controller request: the
    # first API request must observe both disabled settings, including when
    # a revision-qualified preference cache is in use.
    EmojiReaction.create!(account: user.account, status: status, name: '👍')
    expect(EmojiReaction.where(account: user.account, status_id: status.id).count).to eq 1

    unreact
    expect(response).to have_http_status(200)
    expect(EmojiReaction.where(account: user.account, status_id: status.id).count).to eq 0
  end
end
