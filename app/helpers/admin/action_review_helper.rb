# frozen_string_literal: true

module Admin::ActionReviewHelper
  def action_review_queue_nav_label
    count = ActionReviewRequest.pending_state.count
    title = t('admin.action_reviews.title')
    return title unless count.positive?

    t('admin.action_reviews.title_with_count', count: count)
  end

  def action_review_account_label(account)
    admin_account_link_to(account).presence || t('admin.action_reviews.account_unavailable')
  end

  def action_review_resource_label(request)
    t('admin.action_reviews.resource_identity', type: request.resource_type, id: request.resource_id)
  end

  def action_review_resource_display(request)
    label = action_review_resource_label(request)
    resource = request.resource
    return link_to(label, admin_account_path(resource.id)) if resource.is_a?(Account)

    label
  end

  def action_review_reason_summary(request)
    Array(request.reason_codes).join(', ').presence || t('admin.action_reviews.none')
  end

  def action_review_evidence_json(request)
    JSON.pretty_generate(request.evidence.presence || {})
  end

  def action_review_operation_label(operation_type)
    t("admin.action_reviews.operations.#{operation_type}", default: operation_type.to_s)
  end

  def action_review_state_label(state)
    t("admin.action_reviews.states.#{state}")
  end

  def action_review_mode_label(mode)
    t("admin.action_review_settings.modes.#{mode}", default: mode.to_s)
  end

  def action_review_signal_label(signal)
    t("admin.action_reviews.signals.#{signal}", default: signal.to_s)
  end

  def action_review_trigger_label(trigger)
    t("admin.action_reviews.triggers.#{trigger}", default: trigger.to_s)
  end

  # Pending, adapter-backed Follow Import that is still review_required.
  # Terminal, unsupported, missing, or inconsistent rows get no buttons.
  def action_review_decision_controls?(request)
    return false unless request.pending_state?
    return false unless ActionReview::AdapterRegistry.registered?(request.operation_type)

    resource = request.resource
    resource.is_a?(FollowImportBatch) && request.resource_type == 'FollowImportBatch' && resource.review_required_preflight_state?
  end

  def action_review_decision_warning?(request)
    return false unless request.pending_state?
    return false unless request.operation_type == 'follow_import'

    !action_review_decision_controls?(request)
  end
end
