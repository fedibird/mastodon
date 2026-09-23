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

  it 'keeps the moderation parent neutral for a manage_users role' do
    html = navigation_for(user_with_permissions(:manage_users))
    moderation = item(html, 'moderation')

    expect(moderation).to be_present
    expect(moderation.element_children.map(&:name)).to include('span')
    expect(moderation.element_children.map(&:name)).not_to include('a')
    expect(moderation.at_css("a[href='#{helper.admin_accounts_url}']")).to be_present
    expect(moderation.at_css("a[href='#{helper.admin_reports_url}']")).to be_nil
  end

  it 'keeps the admin parent neutral for a manage_settings role' do
    html = navigation_for(user_with_permissions(:manage_settings))
    admin = item(html, 'admin')

    expect(admin).to be_present
    expect(admin.element_children.map(&:name)).to include('span')
    expect(admin.element_children.map(&:name)).not_to include('a')
    expect(admin.at_css("a[href='#{helper.edit_admin_settings_url}']")).to be_present
    expect(admin.at_css("a[href='#{helper.admin_dashboard_url}']")).to be_nil
  end

  it 'shows roles for a manage_roles role and keeps the admin parent neutral' do
    html = navigation_for(user_with_permissions(:manage_roles))
    admin = item(html, 'admin')

    expect(admin).to be_present
    expect(admin.element_children.map(&:name)).to include('span')
    expect(admin.element_children.map(&:name)).not_to include('a')
    expect(admin.at_css("a[href='#{helper.admin_roles_path}']")).to be_present
    expect(admin.at_css("a[href='#{helper.admin_dashboard_url}']")).to be_nil
  end

  it 'keeps Sidekiq and PgHero linked for view_devops' do
    html = navigation_for(user_with_permissions(:view_devops))
    admin = item(html, 'admin')

    expect(admin.element_children.map(&:name)).not_to include('a')
    expect(admin.at_css("a[href='#{helper.sidekiq_url}']")).to be_present
    expect(admin.at_css("a[href='#{helper.pghero_url}']")).to be_present
  end
end
