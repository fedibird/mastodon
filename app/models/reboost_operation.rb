# frozen_string_literal: true

# == Schema Information
#
# Table name: reboost_operations
#
#  id                  :bigint(8)        not null, primary key
#  account_id          :bigint(8)        not null
#  reblog_of_id        :bigint(8)        not null
#  old_status_id       :bigint(8)
#  new_status_id       :bigint(8)
#  state               :string           not null
#  visibility          :string
#  circle_id           :bigint(8)
#  idempotency_key     :string
#  reboost             :boolean          default(FALSE), not null
#  available_at        :datetime
#  removal_started_at  :datetime
#  removal_finished_at :datetime
#  completed_at        :datetime
#  error_code          :string
#  undo_payload        :text
#  undo_inboxes        :jsonb            not null
#  options             :jsonb            not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
class ReboostOperation < ApplicationRecord
  OPEN_STATES = %w(pending federating).freeze
  TERMINAL_STATES = %w(completed failed cancelled).freeze

  belongs_to :account
  belongs_to :reblog_of, class_name: 'Status', optional: true

  scope :open, -> { where(state: OPEN_STATES) }

  def terminal?
    TERMINAL_STATES.include?(state)
  end

  def fail!(code)
    update!(state: 'failed', error_code: code, completed_at: Time.current)
    Reboost::Log.emit('failed', operation_id: id, error: code, account_id: account_id, status_id: reblog_of_id)
  end
end
