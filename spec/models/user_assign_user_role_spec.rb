# frozen_string_literal: true

require 'rails_helper'

# Examples cover the boolean matrix and the dual-write callback together.
# rubocop:disable Metrics/BlockLength
RSpec.describe User, '#assign_user_role!' do
  let(:owner_role) { UserRole.find_by!(name: 'Owner') }
  let(:admin_role) { UserRole.find_by!(name: 'Admin') }
  let(:moderator_role) { UserRole.find_by!(name: 'Moderator') }
  let(:owner) { Fabricate(:user, admin: true) }

  def custom_role(name, position)
    UserRole.create!(name: name, position: position, permissions_as_keys: %w(invite_users))
  end

  def expect_assignment(user, role_id:, admin:, moderator:)
    user.reload
    expect(user.role_id).to eq role_id
    expect(user.admin).to be admin
    expect(user.moderator).to be moderator
  end

  it 'assigns Moderator, Owner, Admin, a custom role, and Everyone with the legacy booleans' do
    user = Fabricate(:user, admin: false, moderator: false)
    custom = custom_role('Assign custom', 4)

    expect(user.assign_user_role!(moderator_role, current_account: owner.account)).to be true
    expect_assignment(user, role_id: moderator_role.id, admin: false, moderator: true)
    expect(user.user_role.id).to eq moderator_role.id

    expect(user.assign_user_role!(owner_role, current_account: owner.account)).to be true
    expect_assignment(user, role_id: owner_role.id, admin: true, moderator: false)

    expect(user.assign_user_role!(admin_role, current_account: owner.account)).to be true
    expect_assignment(user, role_id: admin_role.id, admin: false, moderator: false)

    expect(user.assign_user_role!(custom, current_account: owner.account)).to be true
    expect_assignment(user, role_id: custom.id, admin: false, moderator: false)
    expect(user.user_role.id).to eq custom.id

    expect(user.assign_user_role!(nil, current_account: owner.account)).to be true
    expect_assignment(user, role_id: nil, admin: false, moderator: false)
    expect(user.user_role.everyone?).to be true

    expect(user.assign_user_role!(UserRole.everyone, current_account: owner.account)).to be true
    expect_assignment(user, role_id: nil, admin: false, moderator: false)
  end

  it 'keeps role_id when moving Owner or Moderator onto a custom or Admin role' do
    custom = custom_role('Callback custom', 4)
    owner_user = Fabricate(:user, admin: true)
    moderator_user = Fabricate(:user, moderator: true)
    custom_user = Fabricate(:user, admin: false, moderator: false)
    custom_user.update_columns(role_id: custom.id)

    expect(owner_user.assign_user_role!(custom, current_account: owner.account)).to be true
    expect_assignment(owner_user, role_id: custom.id, admin: false, moderator: false)

    expect(moderator_user.assign_user_role!(custom, current_account: owner.account)).to be true
    expect_assignment(moderator_user, role_id: custom.id, admin: false, moderator: false)

    second_owner = Fabricate(:user, admin: true)
    expect(second_owner.assign_user_role!(admin_role, current_account: owner.account)).to be true
    expect_assignment(second_owner, role_id: admin_role.id, admin: false, moderator: false)

    expect(custom_user.assign_user_role!(nil, current_account: owner.account)).to be true
    expect_assignment(custom_user, role_id: nil, admin: false, moderator: false)
  end

  it 'keeps a custom role across an unrelated save' do
    custom = custom_role('Sticky custom', 4)
    user = Fabricate(:user, admin: true)

    expect(user.assign_user_role!(custom, current_account: owner.account)).to be true
    expect(user.update!(locale: 'ja')).to be true

    expect_assignment(user, role_id: custom.id, admin: false, moderator: false)
  end

  it 'restores the boolean callback after a refused assignment' do
    user = Fabricate(:user, admin: false, moderator: false)
    admin_actor = Fabricate(:user, admin: false, moderator: false)
    admin_actor.update_columns(role_id: admin_role.id)

    expect(user.assign_user_role!(owner_role, current_account: admin_actor.account)).to be false
    expect(user.errors[:role_id]).to be_present
    expect(user.role_id).to be_nil

    expect(user.update!(moderator: true)).to be true
    expect_assignment(user, role_id: moderator_role.id, admin: false, moderator: true)
  end

  it 'allows an equal role and refuses a higher role' do
    admin_actor = Fabricate(:user, admin: false, moderator: false)
    admin_actor.update_columns(role_id: admin_role.id)
    user = Fabricate(:user, admin: false, moderator: false)
    limited = UserRole.create!(name: 'Position 50', position: 50, permissions_as_keys: %w(manage_roles))
    limited_actor = Fabricate(:user, admin: false, moderator: false)
    limited_actor.update_columns(role_id: limited.id)
    lower = custom_role('Lower than 50', 40)
    equal = custom_role('Equal 50', 50)
    higher = custom_role('Higher than 50', 51)

    expect(user.assign_user_role!(moderator_role, current_account: admin_actor.account)).to be true
    expect(user.assign_user_role!(admin_role, current_account: admin_actor.account)).to be true
    expect_assignment(user, role_id: admin_role.id, admin: false, moderator: false)

    everyone = Fabricate(:user, admin: false, moderator: false)
    expect(everyone.assign_user_role!(owner_role, current_account: admin_actor.account)).to be false
    expect_assignment(everyone, role_id: nil, admin: false, moderator: false)

    target = Fabricate(:user, admin: false, moderator: false)
    expect(target.assign_user_role!(lower, current_account: limited_actor.account)).to be true
    expect(target.assign_user_role!(equal, current_account: limited_actor.account)).to be true
    expect_assignment(target, role_id: equal.id, admin: false, moderator: false)

    denied = Fabricate(:user, admin: false, moderator: false)
    expect(denied.assign_user_role!(higher, current_account: limited_actor.account)).to be false
    expect_assignment(denied, role_id: nil, admin: false, moderator: false)
  end
end
# rubocop:enable Metrics/BlockLength
