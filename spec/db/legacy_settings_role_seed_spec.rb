# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'legacy settings role seed' do
  around do |example|
    previous = {
      min_invite_role: Setting.min_invite_role,
      show_staff_badge: Setting.show_staff_badge,
      show_moderator_badge: Setting.show_moderator_badge,
    }
    example.run
  ensure
    previous.each { |key, value| Setting.public_send("#{key}=", value) }
    Rails.cache.clear
  end

  def load_seed
    allow(Doorkeeper::Application).to receive(:create!)
    allow(Rails.env).to receive(:development?).and_return(false)
    load Rails.root.join('db', 'seeds.rb')
  end

  it 'applies the Fedibird invite and badge defaults and stays idempotent' do
    Setting.min_invite_role = 'admin'
    Setting.show_staff_badge = true
    Setting.show_moderator_badge = true

    load_seed
    count = UserRole.count
    load_seed

    everyone = UserRole.find_by!(id: -99)
    moderator = UserRole.find_by!(name: 'Moderator')
    admin = UserRole.find_by!(name: 'Admin')
    owner = UserRole.find_by!(name: 'Owner')
    invite = UserRole::FLAGS[:invite_users]

    expect(everyone.permissions & invite).to eq 0
    expect(everyone.can?(:invite_users)).to be false
    expect(everyone.highlighted).to be false
    expect(moderator.permissions & invite).to eq 0
    expect(moderator.can?(:invite_users)).to be false
    expect(moderator.highlighted).to be true
    expect(admin.permissions & invite).to eq invite
    expect(admin.can?(:invite_users)).to be true
    expect(admin.highlighted).to be true
    expect(owner.highlighted).to be true
    expect(owner.can?(:invite_users)).to be true
    expect(UserRole.count).to eq count
    expect(UserRole.where(name: %w(Moderator Admin Owner)).count).to eq 3
  end
end
