# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'role seed' do
  around do |example|
    previous = Setting.min_invite_role
    example.run
  ensure
    Setting.min_invite_role = previous
    Setting.where(var: %w(show_staff_badge show_moderator_badge)).delete_all
    Rails.cache.clear
  end

  def write_badge_setting(var, value)
    Setting.where(var: var, thing_type: nil, thing_id: nil).delete_all
    Setting.insert!({ var: var, value: YAML.dump(value), thing_type: nil, thing_id: nil, created_at: Time.current, updated_at: Time.current })
  end

  def load_seed
    allow(Doorkeeper::Application).to receive(:create!)
    allow(Rails.env).to receive(:development?).and_return(false)
    User.where.not(role_id: nil).update_all(role_id: nil)
    UserRole.delete_all
    load Rails.root.join('db', 'seeds.rb')
  end

  it 'creates Everyone, Moderator, Admin, and Owner without reading legacy settings' do
    Setting.min_invite_role = 'disabled'
    write_badge_setting('show_staff_badge', false)
    write_badge_setting('show_moderator_badge', false)

    load_seed
    count = UserRole.count
    load_seed

    everyone = UserRole.find_by!(id: -99)
    moderator = UserRole.find_by!(name: 'Moderator')
    admin = UserRole.find_by!(name: 'Admin')
    owner = UserRole.find_by!(name: 'Owner')
    invite = UserRole::FLAGS[:invite_users]

    expect(everyone.permissions).to eq invite
    expect(everyone.can?(:invite_users)).to be true
    expect(everyone.highlighted).to be false
    expect(moderator.highlighted).to be true
    expect(moderator.can?(:invite_users)).to be true
    expect(admin.highlighted).to be true
    expect(admin.can?(:invite_users)).to be true
    expect(owner.highlighted).to be true
    expect(owner.can?(:invite_users)).to be true
    expect(owner.permissions_as_keys).to eq %w(administrator)
    expect(UserRole.count).to eq count
    expect(UserRole.where(name: %w(Moderator Admin Owner)).count).to eq 3
  end
end
