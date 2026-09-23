# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db', 'post_migrate', '20260923060000_final_catch_up_user_role_ids.rb')

RSpec.describe FinalCatchUpUserRoleIds, type: :model do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:owner_role) { UserRole.find_by!(name: 'Owner') }
  let(:moderator_role) { UserRole.find_by!(name: 'Moderator') }

  it 'normalizes stale legacy roles, keeps custom roles, and can run twice' do
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

    described_class.new.up
    described_class.new.up

    expect(regular.reload.role_id).to be_nil
    expect(moderator.reload.role_id).to eq moderator_role.id
    expect(admin.reload.role_id).to eq owner_role.id
    expect(both.reload.role_id).to eq owner_role.id
    expect(demoted.reload.role_id).to be_nil
    expect(custom.reload.role_id).to eq custom_role.id
  end

  it 'does nothing on the way down' do
    user = Fabricate(:user, admin: false, moderator: false)
    user.update_columns(role_id: owner_role.id)

    described_class.new.down

    expect(user.reload.role_id).to eq owner_role.id
  end
end
