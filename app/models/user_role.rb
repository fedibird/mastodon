# frozen_string_literal: true

# == Schema Information
#
# Table name: user_roles
#
#  id          :bigint(8)        not null, primary key
#  name        :string           default(""), not null
#  color       :string           default(""), not null
#  position    :integer          default(0), not null
#  permissions :bigint(8)        default(0), not null
#  highlighted :boolean          default(FALSE), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#

class UserRole < ApplicationRecord
  FLAGS = {
    administrator: (1 << 0),
    view_devops: (1 << 1),
    view_audit_log: (1 << 2),
    view_dashboard: (1 << 3),
    manage_reports: (1 << 4),
    manage_federation: (1 << 5),
    manage_settings: (1 << 6),
    manage_blocks: (1 << 7),
    manage_taxonomies: (1 << 8),
    manage_appeals: (1 << 9),
    manage_users: (1 << 10),
    manage_invites: (1 << 11),
    manage_rules: (1 << 12),
    manage_announcements: (1 << 13),
    manage_custom_emojis: (1 << 14),
    manage_webhooks: (1 << 15),
    invite_users: (1 << 16),
    manage_roles: (1 << 17),
    manage_user_access: (1 << 18),
    delete_user_data: (1 << 19),
  }.freeze

  module Flags
    NONE = 0
    ALL  = FLAGS.values.reduce(&:|)

    DEFAULT = FLAGS[:invite_users]

    CATEGORIES = {
      invites: %i(
        invite_users
      ).freeze,

      moderation: %w(
        view_dashboard
        view_audit_log
        manage_users
        manage_user_access
        delete_user_data
        manage_reports
        manage_appeals
        manage_federation
        manage_blocks
        manage_taxonomies
        manage_invites
      ).freeze,

      administration: %w(
        manage_settings
        manage_rules
        manage_roles
        manage_webhooks
        manage_custom_emojis
        manage_announcements
      ).freeze,

      devops: %w(
        view_devops
      ).freeze,

      special: %i(
        administrator
      ).freeze,
    }.freeze
  end

  # Temporary while boolean dual-write, LegacySettingsSync, promote/demote,
  # and the UserPolicy bridge still look these roles up by name. Drop the
  # reservation when that legacy layer is removed and restore upstream
  # rename/delete semantics.
  LEGACY_BRIDGE_ROLE_NAMES = %w(Owner Admin Moderator).freeze

  attr_writer :current_account

  validates :name, presence: true, unless: :everyone?
  validate :validate_legacy_bridge_name
  validates :color, format: { with: /\A#?(?:[A-F0-9]{3}){1,2}\z/i }, unless: -> { color.blank? }

  validate :validate_permissions_elevation
  validate :validate_position_elevation
  validate :validate_dangerous_permissions
  validate :validate_own_role_edition

  before_validation :set_position
  before_validation :preserve_legacy_managed_fields

  scope :assignable, -> { where.not(id: -99).order(position: :asc) }

  # Inverse of User#assigned_role. User#role remains the legacy string API.
  has_many :users, foreign_key: :role_id, dependent: :nullify, inverse_of: :assigned_role

  def self.nobody
    @nobody ||= UserRole.new(permissions: Flags::NONE, position: -1)
  end

  def self.everyone
    UserRole.find(-99)
  rescue ActiveRecord::RecordNotFound
    UserRole.create!(id: -99, permissions: Flags::DEFAULT)
  end

  # Permissions that make a user an administrative actor for navigation,
  # initial state, and staff notification preferences. invite_users is omitted
  # so a normal user who can invite is not treated as staff.
  ADMINISTRATIVE_PERMISSIONS = %i(
    manage_reports
    manage_users
    manage_taxonomies
    manage_federation
    manage_blocks
    view_audit_log
    view_dashboard
    manage_settings
    manage_rules
    manage_announcements
    manage_custom_emojis
    manage_webhooks
    manage_roles
    manage_invites
    manage_user_access
    delete_user_data
    view_devops
  ).freeze

  def self.that_can(*any_of_privileges)
    all.select { |role| role.can?(*any_of_privileges) }
  end

  def administrative?
    self.class::ADMINISTRATIVE_PERMISSIONS.any? { |privilege| can?(privilege) }
  end

  def everyone?
    id == -99
  end

  def nobody?
    id.nil?
  end

  def permissions_as_keys
    FLAGS.keys.select { |privilege| permissions & FLAGS[privilege] == FLAGS[privilege] }.map(&:to_s)
  end

  def permissions_as_keys=(value)
    self.permissions = value.filter_map(&:presence).reduce(Flags::NONE) { |bitmask, privilege| FLAGS.key?(privilege.to_sym) ? (bitmask | FLAGS[privilege.to_sym]) : bitmask }
  end

  def can?(*any_of_privileges)
    any_of_privileges.any? { |privilege| in_permissions?(privilege) }
  end

  def overrides?(other_role)
    other_role.nil? || position > other_role.position
  end

  def computed_permissions
    # If called on the everyone role, no further computation needed
    return permissions if everyone?

    # If called on the nobody role, no permissions are there to be given
    return Flags::NONE if nobody?

    # Otherwise, compute permissions based on special conditions
    @computed_permissions ||= begin
      permissions = self.class.everyone.permissions | self.permissions

      if permissions & FLAGS[:administrator] == FLAGS[:administrator]
        Flags::ALL
      else
        permissions
      end
    end
  end

  def to_log_human_identifier
    name
  end

  # Role CRUD calls this. Until legacy invite/badge settings are removed, their
  # mirrored fields on the default roles are read-only in that UI.
  def enforce_legacy_managed_fields!
    @enforce_legacy_managed_fields = true
  end

  # LegacySettingsSync is the writer for those mirrored fields, including when
  # a Role CRUD lock is also set on the same instance.
  def allow_legacy_settings_sync!
    @legacy_settings_sync = true
  end

  def legacy_invite_users_locked?
    persisted? && (everyone? || %w(Moderator Admin).include?(name_in_database))
  end

  def legacy_highlighted_locked?
    persisted? && (everyone? || LEGACY_BRIDGE_ROLE_NAMES.include?(name_in_database))
  end

  def legacy_managed_permission?(privilege)
    privilege.to_sym == :invite_users && legacy_invite_users_locked?
  end

  private

  def in_permissions?(privilege)
    raise ArgumentError, "Unknown privilege: #{privilege}" unless FLAGS.key?(privilege)

    computed_permissions & FLAGS[privilege] == FLAGS[privilege]
  end

  def set_position
    self.position = -1 if everyone?
  end

  def validate_own_role_edition
    return unless defined?(@current_account) && @current_account.user_role.id == id

    errors.add(:permissions_as_keys, :own_role) if permissions_changed?
    errors.add(:position, :own_role) if position_changed?
  end

  def validate_permissions_elevation
    errors.add(:permissions_as_keys, :elevated) if defined?(@current_account) && @current_account.user_role.computed_permissions & permissions != permissions
  end

  def validate_position_elevation
    errors.add(:position, :elevated) if defined?(@current_account) && @current_account.user_role.position < position
  end

  def validate_dangerous_permissions
    errors.add(:permissions_as_keys, :dangerous) if everyone? && Flags::DEFAULT & permissions != permissions
  end

  def validate_legacy_bridge_name
    return if name.blank?

    if persisted? && will_save_change_to_name?
      previous_name = name_in_database
      errors.add(:name, :reserved) if legacy_bridge_role_name?(previous_name) || legacy_bridge_role_name?(name)
    elsif new_record? && legacy_bridge_role_name?(name) && self.class.exists?(name: name)
      errors.add(:name, :reserved)
    end
  end

  def legacy_bridge_role_name?(value)
    LEGACY_BRIDGE_ROLE_NAMES.include?(value)
  end

  # Keep the posted value from winning. A disabled checkbox is omitted from the
  # form POST, and a crafted POST must not change the bit either.
  def preserve_legacy_managed_fields
    return if @legacy_settings_sync
    return unless @enforce_legacy_managed_fields
    return unless persisted?

    preserve_legacy_invite_users_bit if legacy_invite_users_locked?
    preserve_legacy_highlighted if legacy_highlighted_locked?
  end

  def preserve_legacy_invite_users_bit
    flag = FLAGS[:invite_users]
    previous = permissions_in_database.to_i & flag
    current = permissions.to_i
    return if (current & flag) == previous

    self.permissions = (current & ~flag) | previous
  end

  def preserve_legacy_highlighted
    if everyone?
      self.highlighted = false
    elsif highlighted != highlighted_in_database
      self.highlighted = highlighted_in_database
    end
  end
end
