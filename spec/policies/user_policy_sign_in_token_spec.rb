# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPolicy do
  def access_role(position)
    UserRole.create!(name: "Access #{position} #{SecureRandom.hex(2)}", position: position, permissions_as_keys: %w(manage_user_access))
  end

  def allow_token_auth?(actor, target)
    %i(disable_sign_in_token_auth? enable_sign_in_token_auth?).all? do |query|
      described_class.new(actor.account, target).public_send(query)
    end
  end

  it 'allows Owner to change Admin, Moderator, and ordinary users' do
    owner = user_with_role('Owner')
    admin = user_with_role(UserRole.find_by!(name: 'Admin'))
    moderator = user_with_role('Moderator')
    ordinary = Fabricate(:user, admin: false, moderator: false)

    expect(allow_token_auth?(owner, admin)).to be true
    expect(allow_token_auth?(owner, moderator)).to be true
    expect(allow_token_auth?(owner, ordinary)).to be true
  end

  it 'allows Admin to change Moderator and ordinary users' do
    admin = user_with_role(UserRole.find_by!(name: 'Admin'))
    moderator = user_with_role('Moderator')
    ordinary = Fabricate(:user, admin: false, moderator: false)

    expect(allow_token_auth?(admin, moderator)).to be true
    expect(allow_token_auth?(admin, ordinary)).to be true
  end

  it 'refuses to let Admin change Owner' do
    admin = user_with_role(UserRole.find_by!(name: 'Admin'))
    owner = user_with_role('Owner')

    expect(allow_token_auth?(admin, owner)).to be false
  end

  it 'refuses peers at the same position' do
    first = user_with_role(access_role(40))
    second = user_with_role(access_role(40))

    expect(allow_token_auth?(first, second)).to be false
  end

  it 'allows a higher custom role to change a lower role' do
    higher = user_with_role(access_role(60))
    lower = user_with_role(access_role(20))

    expect(allow_token_auth?(higher, lower)).to be true
  end

  it 'refuses a non-functional actor' do
    owner = user_with_role('Owner')
    ordinary = Fabricate(:user, admin: false, moderator: false)
    owner.update_columns(disabled: true)

    expect(allow_token_auth?(owner, ordinary)).to be false
  end
end
