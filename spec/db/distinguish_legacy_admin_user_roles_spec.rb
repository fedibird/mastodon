# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db', 'post_migrate', '20260924140000_distinguish_legacy_admin_user_roles.rb')

RSpec.describe DistinguishLegacyAdminUserRoles, type: :model do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:owner_role) { UserRole.find_by!(name: 'Owner') }
  let(:admin_role) { UserRole.find_by!(name: 'Admin') }
  let(:moderator_role) { UserRole.find_by!(name: 'Moderator') }

  def with_hosted(value)
    previous = ENV.fetch('FEDIBIRD_HOSTED') { :unset }
    if value.nil?
      ENV.delete('FEDIBIRD_HOSTED')
    else
      ENV['FEDIBIRD_HOSTED'] = value
    end
    yield
  ensure
    if previous == :unset
      ENV.delete('FEDIBIRD_HOSTED')
    else
      ENV['FEDIBIRD_HOSTED'] = previous
    end
  end

  def run_migration
    described_class.new.up
  end

  it 'does not turn an explicit Admin assignment back into Owner' do
    user = Fabricate(:user, admin: true, moderator: false)
    user.update_columns(role_id: admin_role.id, updated_at: 2.days.ago)
    stamped = user.reload.updated_at

    with_hosted(nil) { run_migration }

    user.reload
    expect(user.role_id).to eq admin_role.id
    expect(user.updated_at).to be_within(1.second).of(stamped)
  end

  it 'does not turn an explicit Owner assignment into Admin when hosted' do
    user = Fabricate(:user, admin: true, moderator: false)
    user.update_columns(role_id: owner_role.id)

    with_hosted('true') { run_migration }

    expect(user.reload.role_id).to eq owner_role.id
  end

  it 'leaves moderators, ordinary users, and custom roles unchanged' do
    custom_role = UserRole.create!(name: 'Helper', permissions_as_keys: %w(manage_reports))
    moderator = Fabricate(:user, admin: false, moderator: true)
    ordinary = Fabricate(:user, admin: false, moderator: false)
    historical_admin = Fabricate(:user, admin: true, moderator: false)
    described_class_user = User.where(id: [moderator.id, ordinary.id])
    described_class_user.update_all(role_id: nil)
    User.where(id: historical_admin.id).update_all(role_id: custom_role.id)
    User.where(id: moderator.id).update_all(role_id: moderator_role.id)

    with_hosted('true') { run_migration }

    expect(moderator.reload.role_id).to eq moderator_role.id
    expect(ordinary.reload.role_id).to be_nil
    expect(historical_admin.reload.role_id).to eq custom_role.id
  end

  it 'creates missing default roles from the seed without assigning users' do
    permissions = {
      'Owner' => owner_role.permissions,
      'Admin' => admin_role.permissions,
      'Moderator' => moderator_role.permissions,
    }
    UserRole.where(name: permissions.keys).delete_all
    admin = Fabricate(:user, admin: true, moderator: false)
    admin.update_columns(role_id: nil)

    run_migration

    owner = UserRole.find_by!(name: 'Owner')
    created_admin = UserRole.find_by!(name: 'Admin')
    created_moderator = UserRole.find_by!(name: 'Moderator')
    expect(admin.reload.role_id).to be_nil
    expect(owner.permissions).to eq permissions['Owner']
    expect(created_admin.permissions).to eq permissions['Admin']
    expect(created_moderator.permissions).to eq permissions['Moderator']
  end

  it 'does not change permissions on roles that already exist' do
    before = UserRole.where(name: %w(Owner Admin Moderator)).pluck(:name, :permissions).to_h

    run_migration

    expect(UserRole.where(name: before.keys).pluck(:name, :permissions).to_h).to eq before
  end

  it 'does nothing on the way down' do
    user = Fabricate(:user, admin: true, moderator: false)
    user.update_columns(role_id: admin_role.id)

    described_class.new.down

    expect(user.reload.role_id).to eq admin_role.id
  end
end
