# frozen_string_literal: true

class PostingContext::RevalidateGroupEvidenceService < BaseService
  Result = Struct.new(:state, :actor, :affiliations, keyword_init: true)

  # Actor refresh runs first and may change the stored affiliations URL.
  # Affiliation refresh then uses that URL. The two results stay separate
  # from permission allowed/unknown.
  # on_step is called after the actor refresh and before affiliations.
  # A false result means this worker no longer owns the lease, so later
  # snapshot writes are skipped. nil tells the worker not to publish a result.
  # request_id fences the actor and affiliation writes that happen after HTTP
  # returns. Losing the lease during a fetch cannot commit over a newer snapshot.
  def call(account, on_step: nil, request_id: nil)
    @on_step = on_step
    @request_id = request_id
    @inline_collection = nil
    @affiliations_invalid = false
    actor = refresh_actor(account)
    return unless lease_held?

    account.reload
    affiliations = refresh_affiliations(account, actor)
    Result.new(state: overall(actor, affiliations), actor: actor, affiliations: affiliations)
  end

  private

  def refresh_actor(account)
    return 'unavailable' unless PostingContext::RevalidationEligibility.usable_actor_uri?(account.uri)

    before = account.permission_definitions_fetched_at
    fetcher = ActivityPub::FetchRemoteAccountService.new
    fetch_options = {
      only_key: false,
      suppress_errors: true,
      defer_group_affiliations: true,
    }
    fence = write_fence(account)
    fetch_options[:revalidation_fence] = fence if fence
    fetched = fetcher.call(account.uri, **fetch_options)
    if fetched
      @inline_collection = fetcher.deferred_group_affiliations_collection
      @affiliations_invalid = fetcher.deferred_group_affiliations_invalid
    end
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
    return 'failed' if @affiliations_invalid

    if @inline_collection.present?
      return affiliation_status(fetch_affiliations(account, collection: @inline_collection))
    end

    # A refreshed actor with no collection URL already withdrew or never had
    # a snapshot. That is not a fetch failure.
    return 'skipped' if actor_status == 'refreshed' && account.affiliations_url.blank?
    return 'unavailable' if account.affiliations_url.blank? || account.suspended?

    affiliation_status(fetch_affiliations(account))
  end

  def fetch_affiliations(account, collection: nil)
    options = {}
    options[:collection] = collection if collection
    fence = write_fence(account)
    options[:revalidation_fence] = fence if fence
    ActivityPub::FetchGroupAffiliationsService.new.call(account, **options)
  end

  def write_fence(account)
    return if @request_id.blank?

    account_id = account.id
    request_id = @request_id
    lambda do |&block|
      PostingContext::RevalidationWriteFence.call(account_id, request_id, &block)
    end
  end

  def affiliation_status(result)
    case result
    when :refreshed
      'refreshed'
    when :failed
      'failed'
    else
      'unavailable'
    end
  end

  def lease_held?
    @on_step.nil? || @on_step.call
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
