# frozen_string_literal: true

# Test users get a role only when a spec assigns one. users.admin and
# users.moderator never select a UserRole, matching production.
module UserRoleFabrication
  # Historical Admin API examples still say 'admin', 'moderator', and 'user'.
  # Those strings are not User#role values. 'admin' is the Owner role.
  LEGACY_FABRICATED_ROLE_NAMES = {
    'admin' => 'Owner',
    'moderator' => 'Moderator',
    'user' => nil,
  }.freeze

  def user_with_role(role, **attributes)
    user = Fabricate(:user, **attributes.merge(admin: false, moderator: false))
    role_record = role.is_a?(UserRole) ? role : UserRole.find_by!(name: role)
    user.update_columns(role_id: role_record.id)
    user
  end

  def user_with_legacy_role_name(name, **attributes)
    mapped = LEGACY_FABRICATED_ROLE_NAMES.fetch(name.to_s)
    user = Fabricate(:user, **attributes.merge(admin: false, moderator: false))
    user.update_columns(role_id: mapped && UserRole.find_by!(name: mapped).id)
    user
  end
end

RSpec.configure do |config|
  config.include UserRoleFabrication
end
