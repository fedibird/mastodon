# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db', 'post_migrate', '20260923040000_catch_up_user_role_ids.rb')

RSpec.describe CatchUpUserRoleIds, type: :model do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:owner_role) { UserRole.find_by!(name: 'Owner') }
  let(:moderator_role) { UserRole.find_by!(name: 'Moderator') }

  def run_catch_up
    described_class.new.up
  end

  it 'repairs drifted default roles and leaves custom roles in place' do
    regular = Fabricate(:user, admin: false, moderator: false)
    moderator = Fabricate(:user, admin: false, moderator: true)
    admin = Fabricate(:user, admin: true, moderator: false)
    both = Fabricate(:user, admin: true, moderator: true)
    demoted = Fabricate(:user, admin: false, moderator: false)
    custom_role = UserRole.create!(name: 'Helper', permissions_as_keys: %w(manage_reports))
    custom = Fabricate(:user, admin: false, moderator: false)

    described_class::User.where(id: [regular, moderator, admin, both, demoted, custom].map(&:id)).update_all(role_id: nil)
    described_class::User.where(id: moderator.id).update_all(role_id: owner_role.id)
    described_class::User.where(id: admin.id).update_all(role_id: moderator_role.id)
    described_class::User.where(id: demoted.id).update_all(role_id: owner_role.id)
    described_class::User.where(id: custom.id).update_all(role_id: custom_role.id)

    run_catch_up
    run_catch_up

    expect(regular.reload.role_id).to be_nil
    expect(moderator.reload.role_id).to eq moderator_role.id
    expect(admin.reload.role_id).to eq owner_role.id
    expect(both.reload.role_id).to eq owner_role.id
    expect(demoted.reload.role_id).to be_nil
    expect(custom.reload.role_id).to eq custom_role.id

    expect(both).to be_admin
    expect(both).to be_moderator
    expect(both.role).to eq owner_role
    expect(moderator.role).to eq moderator_role
    expect(demoted.role).to eq UserRole.everyone
  end
end
