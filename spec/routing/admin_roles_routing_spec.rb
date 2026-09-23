# frozen_string_literal: true

require 'rails_helper'

describe 'admin role routes' do
  include Rails.application.routes.url_helpers

  it 'keeps the legacy promote and demote helpers on the accounts roles controller' do
    expect(post: '/admin/accounts/1/role/promote').to route_to(
      controller: 'admin/accounts/roles',
      action: 'promote',
      account_id: '1'
    )
    expect(post: '/admin/accounts/1/role/demote').to route_to(
      controller: 'admin/accounts/roles',
      action: 'demote',
      account_id: '1'
    )
    expect(promote_admin_account_role_path(1)).to eq '/admin/accounts/1/role/promote'
    expect(demote_admin_account_role_path(1)).to eq '/admin/accounts/1/role/demote'
  end

  it 'routes role management to Admin::RolesController' do
    expect(get: '/admin/roles').to route_to('admin/roles#index')
    expect(get: '/admin/roles/new').to route_to('admin/roles#new')
    expect(post: '/admin/roles').to route_to('admin/roles#create')
    expect(get: '/admin/roles/1/edit').to route_to('admin/roles#edit', id: '1')
    expect(patch: '/admin/roles/1').to route_to('admin/roles#update', id: '1')
    expect(delete: '/admin/roles/1').to route_to('admin/roles#destroy', id: '1')
    expect(get: '/admin/roles/1').to route_to(controller: 'application', action: 'raise_not_found', unmatched_route: 'admin/roles/1')
    expect(admin_roles_path).to eq '/admin/roles'
  end

  it 'routes user role assignment' do
    expect(get: '/admin/users/1/role').to route_to('admin/users/roles#show', user_id: '1')
    expect(put: '/admin/users/1/role').to route_to('admin/users/roles#update', user_id: '1')
    expect(patch: '/admin/users/1/role').to route_to('admin/users/roles#update', user_id: '1')
    expect(admin_user_role_path(1)).to eq '/admin/users/1/role'
  end
end
