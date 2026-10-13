# frozen_string_literal: true

class REST::CredentialAccountSerializer < REST::AccountSerializer
  attributes :source

  has_one :role, serializer: REST::RoleSerializer

  def role
    object.user&.role
  end

  def source
    user = object.user

    {
      privacy: preference_effective(user, 'default_privacy'),
      sensitive: preference_effective(user, 'default_sensitive'),
      language: preference_effective(user, 'default_language'),
      note: object.note,
      fields: object.fields.map(&:to_h),
      follow_requests_count: FollowRequest.where(target_account: object).limit(40).count,
      hide_collections: object.hide_collections,
      discoverable: object.discoverable,
      indexable: object.indexable,
    }
  end

  private

  def preference_reader(user)
    return @preference_reader if defined?(@preference_reader)

    @preference_reader = UserPreferences::Reader.new(user)
  end

  def preference_effective(user, key)
    preference_reader(user).get(key).effective
  end
end
