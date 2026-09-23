# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Sidekiq and PgHero authorization' do
  def denied_route?(error)
    current = error
    seen = 0
    while current && seen < 5
      return true if current.is_a?(ActionController::RoutingError) || current.message.to_s.include?('No route matches')

      seen += 1
      current = current.respond_to?(:cause) ? current.cause : nil
    end
    false
  end

  def devops_allowed?(user, path)
    sign_in user
    get path
    response.status == 200
  rescue StandardError => e
    return false if denied_route?(e)
    # PgHero runs its own queries after the route constraint allows the user.
    return true if path == '/pghero' && e.is_a?(ActiveRecord::StatementInvalid)

    raise
  end

  it 'allows a functional Owner into Sidekiq' do
    expect(devops_allowed?(user_with_role('Owner'), '/sidekiq')).to be true
  end

  it 'allows a functional Owner into PgHero' do
    expect(devops_allowed?(user_with_role('Owner'), '/pghero')).to be true
  end

  it 'allows a custom role with view_devops' do
    role = UserRole.create!(name: 'Ops', position: 50, permissions_as_keys: %w(view_devops))
    user = Fabricate(:user, admin: false, moderator: false)
    user.update_columns(role_id: role.id)

    expect(devops_allowed?(user, '/sidekiq')).to be true
  end

  it 'denies the default Admin role' do
    user = Fabricate(:user, admin: false, moderator: false)
    user.update_columns(role_id: UserRole.find_by!(name: 'Admin').id)

    expect(devops_allowed?(user, '/sidekiq')).to be false
    expect(devops_allowed?(user, '/pghero')).to be false
  end

  it 'denies a disabled user who holds view_devops' do
    role = UserRole.create!(name: 'Ops', position: 50, permissions_as_keys: %w(view_devops))
    user = Fabricate(:user, admin: false, moderator: false)
    user.update_columns(role_id: role.id, disabled: true)

    expect(devops_allowed?(user, '/sidekiq')).to be false
  end

  it 'denies an ordinary user' do
    expect(devops_allowed?(Fabricate(:user), '/sidekiq')).to be false
  end
end
