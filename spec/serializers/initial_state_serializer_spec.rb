# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InitialStateSerializer do
  def serialize(current_account)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        InitialStatePresenter.new(current_account: current_account),
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  it 'returns the Everyone role and keeps an invite-only user off the staff flag' do
    UserRole.everyone.update!(permissions: UserRole::FLAGS[:invite_users])
    user = Fabricate(:user)
    json = serialize(user.account)

    expect(json[:role][:id]).to eq '-99'
    expect(json[:role][:name]).to eq ''
    expect(json[:role][:permissions]).to eq UserRole::FLAGS[:invite_users].to_s
    expect(json[:meta][:is_staff]).to be false
  end

  it 'returns a custom role and marks manage_reports as staff' do
    role = UserRole.create!(name: 'Reporter', position: 4, permissions_as_keys: %w(manage_reports), color: '#abcdef', highlighted: true)
    user = user_with_role(role)
    json = serialize(user.account)

    expect(json[:role][:id]).to eq role.id.to_s
    expect(json[:role][:name]).to eq 'Reporter'
    expect(json[:role][:permissions]).to eq user.role.computed_permissions.to_s
    expect(json[:role][:color]).to eq '#abcdef'
    expect(json[:role][:highlighted]).to be true
    expect(json[:meta][:is_staff]).to be true
  end

  it 'returns the Owner role when role_id is Owner' do
    user = user_with_role('Owner')
    json = serialize(user.account)

    expect(json[:role][:name]).to eq 'Owner'
    expect(json[:role][:permissions]).to eq UserRole::Flags::ALL.to_s
    expect(json[:meta][:is_staff]).to be true
  end

  it 'does not raise when there is no current account' do
    json = nil

    expect { json = serialize(nil) }.not_to raise_error
    expect(json[:role]).to be_nil
    expect(json[:meta]).not_to have_key(:is_staff)
  end
end
