# frozen_string_literal: true

module Admin::GroupAdministrationConcern
  extend ActiveSupport::Concern

  PAGE_SIZE = 25

  included do
    after_action :disallow_shared_cache
  end

  private

  def disallow_shared_cache
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['Pragma'] = 'no-cache'
  end

  # Pundit runs first so verify_authorized passes. The second call is the
  # same rule the services use, so a looser policy cannot open the screen.
  def authorize_group_admin!(record, query)
    authorize record, query
    return if GroupManagement.server_administrator?(current_account)

    raise Mastodon::NotPermittedError
  end

  # Codes and setting snapshots only. Decision notes and storage keys stay
  # off this row and off the Rails log line below.
  def audit_group_action(action, target, code: nil, changes: nil)
    return if target.nil?

    entry = Admin::ActionLog.new(account: current_account, action: action.to_s, target: target)
    if changes
      entry.recorded_changes = changes
    elsif code.present?
      entry.recorded_changes = { 'code' => code.to_s }
    end
    entry.save!
  rescue StandardError => e
    Rails.logger.error("Group administration audit failed action=#{action} target_type=#{target.class.name} target_id=#{target.id} error=#{e.class}")
  end

  def group_admin_audits(*targets)
    records = targets.compact
    return Admin::ActionLog.none if records.empty?

    scopes = records.map do |record|
      Admin::ActionLog.unscoped.where(target_type: record.class.name, target_id: record.id)
    end
    scopes.reduce { |combined, scope| combined.or(scope) }.order(id: :desc).limit(20)
  end
end
