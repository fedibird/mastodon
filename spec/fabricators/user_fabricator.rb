# Admin API specs still pass the old string role names into Fabricate.
# Translate them here, before ActiveRecord's association writer runs.
# This is test fabrication only. User#role= does not accept strings.
module UserLegacyRoleFabrication
  def build_instance
    translate_legacy_user_role! if resolved_class == User
    super
  end

  private

  def translate_legacy_user_role!
    return unless _attributes.key?(:role)
    return if _attributes[:role].nil? || _attributes[:role].is_a?(UserRole)

    role_name = _attributes.delete(:role).to_s
    case role_name
    when 'admin'
      _attributes[:admin] = true
      _attributes[:moderator] = false
      _attributes[:role_id] ||= UserRole.find_by(name: 'Owner')&.id
    when 'moderator'
      _attributes[:admin] = false
      _attributes[:moderator] = true
      _attributes[:role_id] ||= UserRole.find_by(name: 'Moderator')&.id
    when 'user'
      _attributes[:admin] = false
      _attributes[:moderator] = false
      _attributes[:role_id] = nil
    else
      raise ArgumentError, "Unknown fabricated user role #{role_name.inspect}"
    end
  end
end

Fabrication::Generator::ActiveRecord.prepend(UserLegacyRoleFabrication)

Fabricator(:user) do
  account
  email        { sequence(:email) { |i| "#{i}#{Faker::Internet.email}" } }
  password     "123456789"
  confirmed_at { Time.zone.now }
  current_sign_in_at { Time.zone.now }
  agreement    true

  # Build-time convenience only. admin/moderator choose a default role_id so
  # existing specs still create an Owner or Moderator. A later save of those
  # booleans does not assign a role.
  after_build do |user|
    next if user.role_id.present?

    role_name = if user.admin?
                  'Owner'
                elsif user.moderator?
                  'Moderator'
                end
    next if role_name.nil?

    user.role_id = UserRole.find_by(name: role_name)&.id
  end
end
