# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserRole, 'default role names' do
  it 'allows renaming Owner, Admin, and Moderator' do
    %w(Owner Admin Moderator).each do |name|
      role = described_class.find_by!(name: name)
      role.name = "#{name} renamed"

      expect(role.save).to be true
      expect(role.reload.name).to eq "#{name} renamed"
    end
  end

  it 'allows a new custom role that reuses a previous default name after a rename' do
    described_class.find_by!(name: 'Admin').update!(name: 'Administrators')

    role = described_class.create!(name: 'Admin', position: 1, permissions_as_keys: %w(invite_users))

    expect(role).to be_persisted
    expect(role.name).to eq 'Admin'
  end

  it 'allows editing permissions, position, color, and highlighted on Admin' do
    actor = Fabricate(:user, admin: true)
    role = described_class.find_by!(name: 'Admin')
    role.current_account = actor.account
    role.position = 90
    role.color = '#123456'
    role.highlighted = false
    role.permissions_as_keys = %w(manage_roles manage_users)

    expect(role.save).to be true
    expect(role.reload.name).to eq 'Admin'
    expect(role.position).to eq 90
    expect(role.color).to eq '#123456'
    expect(role.highlighted).to be false
    expect(role.permissions_as_keys).to match_array(%w(manage_roles manage_users))
  end
end
