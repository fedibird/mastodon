# frozen_string_literal: true

# == Schema Information
#
# Table name: moderation_subjects
#
#  id              :bigint(8)        not null, primary key
#  account_id      :bigint(8)
#  origin          :integer          default("local"), not null
#  domain          :string
#  actor_uri_hash  :string
#  first_seen_at   :datetime         not null
#  last_seen_at    :datetime         not null
#  deleted_at      :datetime
#  retention_until :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# A moderation-analysis subject, intentionally decoupled from Account.
#
# Interaction and rejection events reference subjects (never Account directly)
# so the observed history can outlive the underlying Account per the retention
# policy. When an Account is deleted/purged the database foreign key nullifies
# +account_id+ (ON DELETE SET NULL); the subject row and its events remain.
class ModerationSubject < ApplicationRecord
  self.table_name = 'moderation_subjects'

  enum origin: { local: 0, remote: 1 }, _suffix: :origin

  belongs_to :account, optional: true

  has_many :actor_interaction_events,
           class_name: 'ModerationInteractionEvent',
           foreign_key: :actor_subject_id,
           inverse_of: :actor_subject,
           dependent: :destroy
  has_many :target_interaction_events,
           class_name: 'ModerationInteractionEvent',
           foreign_key: :target_subject_id,
           inverse_of: :target_subject,
           dependent: :destroy
  has_many :rejections_made,
           class_name: 'ModerationRejectionEvent',
           foreign_key: :rejector_subject_id,
           inverse_of: :rejector_subject,
           dependent: :destroy
  has_many :rejections_received,
           class_name: 'ModerationRejectionEvent',
           foreign_key: :rejected_subject_id,
           inverse_of: :rejected_subject,
           dependent: :destroy

  validates :origin, presence: true
  validates :first_seen_at, :last_seen_at, presence: true

  scope :active, -> { where(deleted_at: nil) }
  scope :tombstoned, -> { where.not(deleted_at: nil) }
  # Detached from their account (FK nullified on account deletion) but not yet
  # tombstoned — e.g. deleted through a path that bypassed the service hook.
  scope :orphaned, -> { where(account_id: nil, deleted_at: nil) }
  # Tombstoned subjects whose retention window has elapsed.
  scope :expired, ->(now = Time.now.utc) { where.not(retention_until: nil).where('retention_until <= ?', now) }

  # Resolve (or create) the subject that represents +account+, keeping the
  # denormalized origin/domain and +last_seen_at+ fresh. Accepts either an
  # Account or an already-resolved ModerationSubject for caller convenience.
  def self.for_account!(account, observed_at: Time.now.utc)
    return account if account.is_a?(ModerationSubject)

    raise ArgumentError, 'account is required' if account.nil?

    subject = find_or_create_by!(account_id: account.id) do |s|
      s.origin        = account.local? ? :local : :remote
      s.domain        = account.domain
      s.first_seen_at = observed_at
      s.last_seen_at  = observed_at
    end

    subject.refresh_from_account!(account, observed_at: observed_at)
    subject
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def refresh_from_account!(account, observed_at: Time.now.utc)
    self.origin      = account.local? ? :local : :remote
    self.domain      = account.domain
    self.last_seen_at = observed_at
    save! if changed?
  end

  # Tombstone every live subject bound to +account+ before the account row is
  # deleted (afterwards the FK nullifies account_id and it can't be found by id).
  def self.tombstone_for_account!(account, now: Time.now.utc)
    return if account.nil?

    where(account_id: account.id, deleted_at: nil).find_each { |subject| subject.tombstone!(now: now) }
  end

  def tombstone!(now: Time.now.utc)
    update!(deleted_at: now, retention_until: Moderation::RetentionPolicy.expire_at(now))
  end

  def tombstoned?
    deleted_at.present?
  end
end
