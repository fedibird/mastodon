# frozen_string_literal: true

# == Schema Information
#
# Table name: action_review_requests
#
#  id                  :bigint(8)        not null, primary key
#  operation_type      :string           not null
#  state               :integer          default("pending"), not null
#  actor_account_id    :bigint(8)
#  resource_type       :string           not null
#  resource_id         :bigint(8)        not null
#  trigger             :string           not null
#  signal_level        :string           not null
#  policy_mode         :string           not null
#  policy_version      :string           not null
#  evaluator_version   :string
#  reason_codes        :jsonb            not null
#  evidence            :jsonb            not null
#  requested_at        :datetime         not null
#  reviewed_at         :datetime
#  reviewer_account_id :bigint(8)
#  decision_note       :text
#  lock_version        :integer          default(0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
# Generic Action Review audit snapshot. Records why a human review was
# requested for a durable operation resource. Actor/reviewer accounts and
# the referenced resource may later disappear; the row remains readable.
# This model does not execute, release, or stop the underlying operation.
class ActionReviewRequest < ApplicationRecord
  enum state: { pending: 0, approved: 1, rejected: 2, cancelled: 3 }, _suffix: :state

  belongs_to :actor_account, class_name: 'Account', optional: true
  belongs_to :reviewer_account, class_name: 'Account', optional: true
  belongs_to :resource, polymorphic: true, optional: true

  validates :operation_type, presence: true
  validate :operation_type_must_be_registered
  validates :state, presence: true
  validates :trigger, presence: true
  validates :signal_level, presence: true, inclusion: { in: ActionReview::OperationRegistry::SIGNAL_LEVELS }
  validates :policy_mode, presence: true, inclusion: { in: ActionReview::OperationRegistry::POLICY_MODES }
  validates :policy_version, presence: true
  validates :requested_at, presence: true
  validates :resource_type, presence: true
  validates :resource_id, presence: true
  validates :resource_id, uniqueness: {
    scope: [:operation_type, :resource_type],
    conditions: -> { pending_state },
  }, if: :pending_state?
  validate :reason_codes_must_be_array
  validate :evidence_must_be_object

  private

  def operation_type_must_be_registered
    return if operation_type.blank?
    return if ActionReview::OperationRegistry.registered?(operation_type)

    errors.add(:operation_type, 'is not a registered action review operation')
  end

  def reason_codes_must_be_array
    errors.add(:reason_codes, 'must be an array') unless reason_codes.is_a?(Array)
  end

  def evidence_must_be_object
    errors.add(:evidence, 'must be an object') unless evidence.is_a?(Hash)
  end
end
