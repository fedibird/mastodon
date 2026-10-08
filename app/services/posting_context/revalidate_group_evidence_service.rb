# frozen_string_literal: true

class PostingContext::RevalidateGroupEvidenceService < BaseService
  Result = Struct.new(:state, :actor, :affiliations, keyword_init: true)

  # Actor refresh runs first and may change the stored affiliations URL.
  # Affiliation refresh then uses that URL. The two results stay separate
  # from permission allowed/unknown.
  def call(account)
    actor = refresh_actor(account)
    account.reload
    affiliations = refresh_affiliations(account, actor)
    Result.new(state: overall(actor, affiliations), actor: actor, affiliations: affiliations)
  end

  private

  def refresh_actor(account)
    return 'unavailable' unless PostingContext::RevalidationEligibility.usable_actor_uri?(account.uri)

    before = account.permission_definitions_fetched_at
    fetched = ActivityPub::FetchRemoteAccountService.new.call(
      account.uri,
      only_key: false,
      suppress_errors: true,
      defer_group_affiliations: true
    )
    account.reload
    return 'failed' if fetched.nil?
    return 'skipped' unless account.group?
    return 'refreshed' if definitions_advanced?(account, before)

    'failed'
  end

  def definitions_advanced?(account, before)
    fetched_at = account.permission_definitions_fetched_at
    return false if fetched_at.blank?
    return true if before.blank?

    fetched_at > before
  end

  def refresh_affiliations(account, actor_status)
    return 'skipped' if actor_status == 'skipped' || !account.group?
    # A refreshed actor with no collection URL already withdrew or never had
    # a snapshot. That is not a fetch failure.
    return 'skipped' if actor_status == 'refreshed' && account.affiliations_url.blank?
    return 'unavailable' if account.affiliations_url.blank? || account.suspended?

    case ActivityPub::FetchGroupAffiliationsService.new.call(account)
    when :refreshed
      'refreshed'
    when :failed
      'failed'
    else
      'unavailable'
    end
  end

  def overall(actor, affiliations)
    return 'completed' if actor == 'refreshed' && %w(refreshed skipped).include?(affiliations)
    return 'completed' if actor == 'skipped' && affiliations == 'skipped'
    return 'partial' if refreshed_or_failed?(actor) && refreshed_or_failed?(affiliations) && actor != affiliations
    return 'partial' if actor == 'refreshed' && affiliations == 'unavailable'
    return 'partial' if actor == 'failed' && affiliations == 'refreshed'

    'failed'
  end

  def refreshed_or_failed?(status)
    %w(refreshed failed).include?(status)
  end
end
