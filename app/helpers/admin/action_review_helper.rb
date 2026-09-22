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

  # Pending, registered, and actionable through that operation's adapter.
  # Terminal, unsupported, missing, or inconsistent rows get no buttons.
  def action_review_decision_controls?(request)
    return false unless request.pending_state?

    ActionReview::AdapterRegistry.actionable?(request)
  end

  def action_review_decision_warning?(request)
    return false unless request.pending_state?
    return false unless ActionReview::AdapterRegistry.registered?(request.operation_type)

    !action_review_decision_controls?(request)
  end

  def action_review_decision_warning_text(request)
    if request.operation_type == 'invite_creation'
      t('admin.action_reviews.inconsistent_invite')
    else
      t('admin.action_reviews.inconsistent_resource')
    end
  end

  def action_review_stop_confirm(request)
    if request.operation_type == 'invite_creation'
      t('admin.action_reviews.invite_stop_confirm')
    else
      t('admin.action_reviews.stop_confirm')
    end
  end

  def action_review_invite_lifetime(seconds)
    return t('admin.action_reviews.invite_creation.no_expiry') if seconds.nil?
    return t("invites.expires_in.#{seconds}") if I18n.exists?("invites.expires_in.#{seconds}")

    t('admin.action_reviews.invite_creation.lifetime_seconds', count: seconds.to_i)
  end

  def action_review_invite_status(request)
    case request.state
    when 'pending'
      t('admin.action_reviews.invite_creation.waiting')
    when 'approved'
      t('admin.action_reviews.invite_creation.approved')
    when 'rejected'
      t('admin.action_reviews.invite_creation.stopped')
    else
      action_review_state_label(request.state)
    end
  end
end
