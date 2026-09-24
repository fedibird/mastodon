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

  it 'assigns legacy admins to Owner when FEDIBIRD_HOSTED is unset' do
    admin = Fabricate(:user, admin: true, moderator: false)
    described_class::User.where(id: admin.id).update_all(role_id: nil)

    with_hosted(nil) { run_migration }

    expect(admin.reload.role_id).to eq owner_role.id
    expect(admin.role_id).not_to eq admin_role.id
  end

  it 'assigns legacy admins already on Owner or Admin to Owner when the variable is not true' do
    on_owner = Fabricate(:user, admin: true, moderator: true)
    on_admin = Fabricate(:user, admin: true, moderator: false)
    described_class::User.where(id: on_owner.id).update_all(role_id: owner_role.id)
    described_class::User.where(id: on_admin.id).update_all(role_id: admin_role.id)

    with_hosted('false') { run_migration }

    expect(on_owner.reload.role_id).to eq owner_role.id
    expect(on_admin.reload.role_id).to eq owner_role.id
  end

  it 'assigns legacy admins to Admin when FEDIBIRD_HOSTED=true' do
    admin = Fabricate(:user, admin: true, moderator: false)
    described_class::User.where(id: admin.id).update_all(role_id: owner_role.id)

    with_hosted('true') { run_migration }

    expect(admin.reload.role_id).to eq admin_role.id
  end

  it 'assigns legacy moderators to Moderator and leaves ordinary users alone' do
    moderator = Fabricate(:user, admin: false, moderator: true)
    ordinary = Fabricate(:user, admin: false, moderator: false)
    described_class::User.where(id: [moderator.id, ordinary.id]).update_all(role_id: nil)

    with_hosted(nil) { run_migration }

    expect(moderator.reload.role_id).to eq moderator_role.id
    expect(ordinary.reload.role_id).to be_nil
  end

  it 'does not overwrite a custom role on a historical admin or moderator' do
    custom_role = UserRole.create!(name: 'Helper', permissions_as_keys: %w(manage_reports))
    admin = Fabricate(:user, admin: true, moderator: false)
    moderator = Fabricate(:user, admin: false, moderator: true)
    described_class::User.where(id: [admin.id, moderator.id]).update_all(role_id: custom_role.id)

    with_hosted('true') { run_migration }

    expect(admin.reload.role_id).to eq custom_role.id
    expect(moderator.reload.role_id).to eq custom_role.id
  end

  it 'is idempotent when FEDIBIRD_HOSTED=true' do
    admin = Fabricate(:user, admin: true, moderator: false)
    moderator = Fabricate(:user, admin: false, moderator: true)
    described_class::User.where(id: [admin.id, moderator.id]).update_all(role_id: nil)

    with_hosted('true') do
      run_migration
      run_migration
    end

    expect(admin.reload.role_id).to eq admin_role.id
    expect(moderator.reload.role_id).to eq moderator_role.id
  end

  it 'is idempotent when FEDIBIRD_HOSTED is unset' do
    admin = Fabricate(:user, admin: true, moderator: false)
    moderator = Fabricate(:user, admin: false, moderator: true)
    described_class::User.where(id: admin.id).update_all(role_id: admin_role.id)
    described_class::User.where(id: moderator.id).update_all(role_id: nil)

    with_hosted(nil) do
      run_migration
      run_migration
    end

    expect(admin.reload.role_id).to eq owner_role.id
    expect(moderator.reload.role_id).to eq moderator_role.id
  end

  it 'creates missing default roles from the seed and resolves them by name' do
    permissions = {
      'Owner' => owner_role.permissions,
      'Admin' => admin_role.permissions,
      'Moderator' => moderator_role.permissions,
    }
    UserRole.where(name: permissions.keys).delete_all
    admin = Fabricate(:user, admin: true, moderator: false)
    moderator = Fabricate(:user, admin: false, moderator: true)
    described_class::User.where(id: [admin.id, moderator.id]).update_all(role_id: nil)

    with_hosted(nil) { run_migration }

    owner = UserRole.find_by!(name: 'Owner')
    created_admin = UserRole.find_by!(name: 'Admin')
    created_moderator = UserRole.find_by!(name: 'Moderator')
    expect([owner.id, created_admin.id, created_moderator.id]).to all(be_positive)
    expect(admin.reload.role_id).to eq owner.id
    expect(moderator.reload.role_id).to eq created_moderator.id
    expect(owner.permissions).to eq permissions['Owner']
    expect(created_admin.permissions).to eq permissions['Admin']
    expect(created_moderator.permissions).to eq permissions['Moderator']
  end

  it 'does not change permissions on roles that already exist' do
    before = UserRole.where(name: %w(Owner Admin Moderator)).pluck(:name, :permissions).to_h

    with_hosted('true') { run_migration }

    expect(UserRole.where(name: before.keys).pluck(:name, :permissions).to_h).to eq before
  end

  it 'updates role_id without loading users or running callbacks' do
    admin = Fabricate(:user, admin: true, moderator: false)
    described_class::User.where(id: admin.id).update_all(role_id: nil, updated_at: 2.days.ago)
    stamped = admin.reload.updated_at

    expect(described_class::User).not_to receive(:find_each)
    with_hosted(nil) { run_migration }

    admin.reload
    expect(admin.role_id).to eq owner_role.id
    expect(admin.updated_at).to be_within(1.second).of(stamped)
  end

  it 'does nothing on the way down' do
    admin = Fabricate(:user, admin: true, moderator: false)
    admin.update_columns(role_id: admin_role.id)

    described_class.new.down

    expect(admin.reload.role_id).to eq admin_role.id
  end
end
