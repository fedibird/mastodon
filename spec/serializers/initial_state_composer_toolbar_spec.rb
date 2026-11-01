# frozen_string_literal: true

require 'rails_helper'

describe InitialStateSerializer do
  def serialize(current_account)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        InitialStatePresenter.new(current_account: current_account),
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  it 'gives the WebUI the saved toolbar and a safe default for garbage' do
    user = Fabricate(:user)
    expect(serialize(user.account)[:meta][:composer_toolbar].map { |item| item[:id] }).to eq ComposerToolbarPreference::IDS

    saved = ComposerToolbarPreference.dump([
                                             { 'id' => 'media', 'placement' => 'hidden' },
                                             { 'id' => 'posting_account', 'placement' => 'menu' },
                                             { 'id' => 'cw', 'placement' => 'visible' },
                                             { 'id' => 'language', 'placement' => 'visible' },
                                             { 'id' => 'datetime', 'placement' => 'visible' },
                                             { 'id' => 'searchability', 'placement' => 'hidden' },
                                             { 'id' => 'poll', 'placement' => 'menu' },
                                           ])
    user.settings['composer_toolbar'] = saved
    toolbar = serialize(user.account)[:meta][:composer_toolbar]

    expect(toolbar.map { |item| item[:id] }).to eq %w(media posting_account cw language datetime searchability poll)
    expect(toolbar.first[:placement]).to eq 'hidden'

    user.settings['composer_toolbar'] = 'garbage'
    expect(serialize(user.account)[:meta][:composer_toolbar].map { |item| item[:placement] }).to eq %w(visible visible visible visible menu menu menu)
  end
end
