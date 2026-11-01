# frozen_string_literal: true

# == Schema Information
#
# Table name: group_creation_decisions
#
#  id                        :bigint(8)        not null, primary key
#  group_creation_request_id :bigint(8)        not null
#  reviewer_account_id       :bigint(8)        not null
#  group_account_id          :bigint(8)
#  action                    :integer          not null
#  decision_note             :text
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#
# Append-only audit of one administrator decision. The request row stores
# the current terminal state. This row is the copy written in the same
# transaction, and a request has at most one. Cancellation is the
# requester's action and is not recorded here.
class GroupCreationDecision < ApplicationRecord
  enum action: { approved: 0, rejected: 1 }

  belongs_to :group_creation_request, inverse_of: :decision
  belongs_to :reviewer_account, class_name: 'Account'
  belongs_to :group_account, class_name: 'Account', optional: true

  validates :action, presence: true
  validates :group_creation_request_id, uniqueness: true
  validate :shape_matches_action
  validate :reviewer_is_administrator
  validate :identity_is_fixed, on: :update

  def self.record!(request)
    create!(
      group_creation_request: request,
      reviewer_account: request.reviewer_account,
      group_account: request.group_account,
      action: request.approved? ? :approved : :rejected,
      decision_note: request.decision_note
    )
  end

  private

  def shape_matches_action
    if approved?
      errors.add(:group_account, :blank) if group_account_id.blank?
      errors.add(:group_creation_request, :invalid) unless group_creation_request&.approved?
      return
    end

    errors.add(:decision_note, :blank) if decision_note.blank?
    errors.add(:group_account, :present) if group_account_id.present?
    errors.add(:group_creation_request, :invalid) unless group_creation_request&.rejected?
  end

  def reviewer_is_administrator
    errors.add(:reviewer_account, :invalid) unless GroupManagement.server_administrator?(reviewer_account)
  end

  def identity_is_fixed
    %w(group_creation_request_id reviewer_account_id group_account_id action decision_note).each do |attribute|
      errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
    end
  end
end
