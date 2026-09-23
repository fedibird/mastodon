# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Owner and Moderator authorization' do # rubocop:disable Metrics/BlockLength
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:owner) { user_with_role('Owner') }
  let(:moderator) { user_with_role('Moderator') }
  let(:ordinary) { Fabricate(:user, admin: false, moderator: false) }
  let(:target) { Fabricate(:account) }

  it 'leaves an admin boolean on Everyone' do
    user = Fabricate(:user, admin: true, moderator: false)

    expect(user.role_id).to be_nil
    expect(user.role).to eq UserRole.everyone
    expect(user).to be_admin
    expect(user).not_to be_moderator
    expect(user.can?(:manage_reports)).to be false
    expect(user.can?(:view_devops)).to be false
    expect(AccountPolicy.new(user.account, target).index?).to be false
  end

  it 'leaves a moderator boolean on Everyone' do
    user = Fabricate(:user, admin: false, moderator: true)

    expect(user.role_id).to be_nil
    expect(user.role).to eq UserRole.everyone
    expect(user).to be_moderator
    expect(user).not_to be_admin
    expect(user.can?(:manage_reports)).to be false
    expect(user.can?(:manage_users)).to be false
    expect(ReportPolicy.new(user.account, nil).index?).to be false
  end

  it 'gives a functional Owner every permission' do
    expect(owner.role.name).to eq 'Owner'
    expect(owner).not_to be_admin
    expect(owner).not_to be_moderator
    expect(owner.can?(:view_devops)).to be true
    expect(owner.can?(:manage_settings)).to be true
    expect(owner.can?(:manage_reports)).to be true
    expect(AccountPolicy.new(owner.account, target).show?).to be true
    expect(SettingsPolicy.new(owner.account, nil).show?).to be true
    expect(DashboardPolicy.new(owner.account, nil).index?).to be true
  end

  it 'gives a functional Moderator the Moderator permission set' do
    expect(moderator.role.name).to eq 'Moderator'
    expect(moderator).not_to be_admin
    expect(moderator).not_to be_moderator
    expect(moderator.can?(:manage_reports)).to be true
    expect(moderator.can?(:manage_users)).to be true
    expect(moderator.can?(:view_dashboard)).to be true
    expect(moderator.can?(:view_audit_log)).to be true
    expect(moderator.can?(:manage_taxonomies)).to be true
    expect(moderator.can?(:manage_settings)).to be false
    expect(moderator.can?(:view_devops)).to be false
    expect(moderator.can?(:manage_federation)).to be false
    expect(ReportPolicy.new(moderator.account, nil).index?).to be true
    expect(SettingsPolicy.new(moderator.account, nil).show?).to be false
    expect(DashboardPolicy.new(moderator.account, nil).index?).to be true
  end

  it 'does not grant an ordinary user administrative permissions' do
    expect(ordinary.role).to be_everyone
    expect(ordinary.can?(:manage_reports)).to be false
    expect(ordinary.can?(:manage_users)).to be false
    expect(ordinary.administrative?).to be false
    expect(AccountPolicy.new(ordinary.account, target).index?).to be false
  end

  it 'compares custom roles by position and refuses peers' do
    higher = UserRole.create!(name: 'Higher', position: 20, permissions_as_keys: %w(manage_reports))
    lower = UserRole.create!(name: 'Lower', position: 5, permissions_as_keys: %w(manage_reports))
    peer = UserRole.create!(name: 'Peer', position: 20, permissions_as_keys: %w(manage_reports))
    actor = Fabricate(:user)
    lower_user = Fabricate(:user)
    peer_user = Fabricate(:user)
    actor.update_columns(role_id: higher.id, admin: false, moderator: false)
    lower_user.update_columns(role_id: lower.id, admin: false, moderator: false)
    peer_user.update_columns(role_id: peer.id, admin: false, moderator: false)

    expect(higher.overrides?(lower)).to be true
    expect(higher.overrides?(peer)).to be false
    expect(AccountPolicy.new(actor.account, lower_user.account).warn?).to be true
    expect(AccountPolicy.new(actor.account, peer_user.account).warn?).to be false
    expect(UserRole.find_by!(name: 'Owner').overrides?(UserRole.find_by!(name: 'Admin'))).to be true
    expect(UserRole.find_by!(name: 'Admin').overrides?(UserRole.find_by!(name: 'Moderator'))).to be true
    expect(UserRole.find_by!(name: 'Moderator').overrides?(UserRole.everyone)).to be true
  end
end
