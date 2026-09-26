# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'admin navigation parents', type: :helper do
  def user_with_permissions(*permissions)
    role = UserRole.create!(name: "Nav #{permissions.join('-')}", position: 40, permissions_as_keys: permissions.map(&:to_s))
    user = Fabricate(:user, admin: false, moderator: false)
    user.update_columns(role_id: role.id)
    user
  end

  def navigation_for(user)
    helper.define_singleton_method(:current_user) { user }
    helper.define_singleton_method(:current_account) { user.account }
    allow(helper.controller).to receive(:view_context).and_return(helper)
    helper.render_navigation(expand_all: true)
  end

  def item(html, id)
    Nokogiri::HTML.fragment(html).at_css("li##{id}")
  end

  def parent_link(node)
    node.element_children.find { |child| child.name == 'a' }
  end

  it 'links the moderation parent to the first manage_reports child' do
    html = navigation_for(user_with_permissions(:manage_reports))
    moderation = item(html, 'moderation')

    expect(moderation).to be_present
    expect(parent_link(moderation)['href']).to eq helper.admin_moderation_evidence_snapshots_url
    expect(moderation.at_css("a[href='#{helper.admin_reports_url}']")).to be_present
    expect(moderation.at_css("a[href='#{helper.admin_accounts_url}']")).to be_nil
    expect(moderation.at_css("a[href='#{helper.admin_action_logs_url}']")).to be_nil
  end

  it 'links the moderation parent to accounts when only manage_users is granted' do
    html = navigation_for(user_with_permissions(:manage_users))
    moderation = item(html, 'moderation')

    expect(moderation).to be_present
    expect(parent_link(moderation)['href']).to eq helper.admin_accounts_url
    expect(moderation.at_css("a[href='#{helper.admin_accounts_url}']")).to be_present
    expect(moderation.at_css("a[href='#{helper.admin_reports_url}']")).to be_nil
  end

  it 'links the moderation parent to action logs when only view_audit_log is granted' do
    html = navigation_for(user_with_permissions(:view_audit_log))
    moderation = item(html, 'moderation')

    expect(moderation).to be_present
    expect(parent_link(moderation)['href']).to eq helper.admin_action_logs_url
    expect(moderation.at_css("a[href='#{helper.admin_action_logs_url}']")).to be_present
    expect(moderation.at_css("a[href='#{helper.admin_reports_url}']")).to be_nil
    expect(moderation.at_css("a[href='#{helper.admin_accounts_url}']")).to be_nil
  end

  it 'links the admin parent to the dashboard when only view_dashboard is granted' do
    html = navigation_for(user_with_permissions(:view_dashboard))
    admin = item(html, 'admin')

    expect(admin).to be_present
    expect(parent_link(admin)['href']).to eq helper.admin_dashboard_url
    expect(admin.at_css("a[href='#{helper.admin_dashboard_url}']")).to be_present
    expect(admin.at_css("a[href='#{helper.edit_admin_settings_url}']")).to be_nil
    expect(admin.at_css("a[href='#{helper.admin_roles_path}']")).to be_nil
  end

  it 'links the admin parent to settings when only manage_settings is granted' do
    html = navigation_for(user_with_permissions(:manage_settings))
    admin = item(html, 'admin')

    expect(admin).to be_present
    expect(parent_link(admin)['href']).to eq helper.edit_admin_settings_url
    expect(admin.at_css("a[href='#{helper.edit_admin_settings_url}']")).to be_present
    expect(admin.at_css("a[href='#{helper.admin_dashboard_url}']")).to be_nil
  end

  it 'links the admin parent to roles when only manage_roles is granted' do
    html = navigation_for(user_with_permissions(:manage_roles))
    admin = item(html, 'admin')

    expect(admin).to be_present
    expect(parent_link(admin)['href']).to eq helper.admin_roles_path
    expect(admin.at_css("a[href='#{helper.admin_roles_path}']")).to be_present
    expect(admin.at_css("a[href='#{helper.admin_dashboard_url}']")).to be_nil
  end

  it 'links the admin parent to webhooks when only manage_webhooks is granted' do
    html = navigation_for(user_with_permissions(:manage_webhooks))
    admin = item(html, 'admin')

    expect(admin).to be_present
    expect(parent_link(admin)['href']).to eq helper.admin_webhooks_path
    expect(admin.at_css("a[href='#{helper.admin_webhooks_path}']")).to be_present
    expect(admin.at_css("a[href='#{helper.admin_dashboard_url}']")).to be_nil
  end

  it 'keeps Sidekiq and PgHero linked for view_devops and points the parent at Sidekiq' do
    html = navigation_for(user_with_permissions(:view_devops))
    admin = item(html, 'admin')

    expect(parent_link(admin)['href']).to eq helper.sidekiq_url
    expect(admin.at_css("a[href='#{helper.sidekiq_url}']")).to be_present
    expect(admin.at_css("a[href='#{helper.pghero_url}']")).to be_present
  end
end
