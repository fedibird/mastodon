# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserRole, 'legacy bridge names' do
  it 'rejects renaming Owner, Admin, and Moderator' do
    %w(Owner Admin Moderator).each do |name|
      role = described_class.find_by!(name: name)
      role.name = "#{name} renamed"

      expect(role).not_to be_valid
      expect(role.errors[:name]).to be_present
      expect(role.reload.name).to eq name
    end
  end

  it 'rejects a new custom role that copies a reserved name' do
    role = described_class.new(name: 'Admin', position: 1)

    expect(role).not_to be_valid
    expect(role.errors[:name]).to be_present
  end

  it 'still allows the first seed insert and later permission updates' do
    described_class.find_by!(name: 'Moderator').destroy!

    role = described_class.create_with(
      position: 10,
      permissions_as_keys: %w(manage_reports),
      highlighted: true
    ).find_or_create_by(name: 'Moderator')

    expect(role).to be_persisted
    expect(role.errors).to be_empty

    role.permissions_as_keys = %w(manage_reports manage_users)
    expect(role.save).to be true
    expect(role.reload.name).to eq 'Moderator'
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
  end
end
