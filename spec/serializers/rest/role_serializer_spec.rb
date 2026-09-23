# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::RoleSerializer do
  def serialize(role)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(role, serializer: described_class).to_json,
      symbolize_names: true
    )
  end

  describe 'Everyone' do
    let(:everyone) { UserRole.everyone }
    let(:json) { serialize(everyone) }

    it 'returns the seeded identity and its own permissions as strings' do
      expect(json[:id]).to eq '-99'
      expect(json[:name]).to eq ''
      expect(json[:permissions]).to eq everyone.computed_permissions.to_s
      expect(json[:highlighted]).to be false
      expect(json[:id]).to be_a(String)
      expect(json[:permissions]).to be_a(String)
    end
  end

  describe 'custom role' do
    it 'returns Everyone permissions combined with the role permissions' do
      UserRole.everyone.update!(permissions: UserRole::FLAGS[:invite_users])
      custom = UserRole.create!(
        name: 'Helper',
        position: 5,
        permissions_as_keys: %w(manage_reports),
        color: '#112233',
        highlighted: true
      )

      json = serialize(custom)
      combined = UserRole::FLAGS[:invite_users] | UserRole::FLAGS[:manage_reports]

      expect(json[:id]).to eq custom.id.to_s
      expect(json[:name]).to eq 'Helper'
      expect(json[:color]).to eq '#112233'
      expect(json[:highlighted]).to be true
      expect(json[:permissions]).to eq combined.to_s
      expect(json[:permissions]).to eq custom.computed_permissions.to_s
      expect(json[:permissions]).not_to eq custom.permissions.to_s
      expect(json[:id]).to be_a(String)
      expect(json[:permissions]).to be_a(String)
    end
  end

  describe 'Owner' do
    it 'expands the administrator flag to every permission' do
      owner = UserRole.find_by!(name: 'Owner')
      json = serialize(owner)

      expect(json[:name]).to eq 'Owner'
      expect(json[:permissions]).to eq UserRole::Flags::ALL.to_s
      expect(json[:permissions]).to eq owner.computed_permissions.to_s
      expect(json[:id]).to be_a(String)
      expect(json[:permissions]).to be_a(String)
    end
  end
end
