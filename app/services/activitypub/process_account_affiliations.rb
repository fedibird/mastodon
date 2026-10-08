# frozen_string_literal: true

module ActivityPub::ProcessAccountAffiliations
  # Present only when defer_group_affiliations asked this refresh not to
  # enqueue SynchronizeGroupAffiliationsWorker. The collection comes from the
  # actor document that already passed JSON-LD processing.
  attr_reader :deferred_group_affiliations_collection, :deferred_group_affiliations_invalid

  private

  def assign_group_affiliations_url!
    @account.affiliations_url = @account.group? ? normalized_affiliations_url : nil
  end

  def check_group_affiliations!
    @deferred_group_affiliations_collection = nil
    @deferred_group_affiliations_invalid = false

    if enqueue_group_affiliations?
      # P17 refreshes affiliations itself after the actor update. Skip only
      # the automatic enqueue. Withdrawing a removed collection still runs.
      if @options[:defer_group_affiliations]
        @deferred_group_affiliations_collection = deferred_inline_collection
      else
        enqueue_group_affiliations_sync!
      end
    elsif deferred_affiliations_invalid?
      @deferred_group_affiliations_invalid = true
    else
      withdraw_group_affiliations_cache!
    end
  end

  def enqueue_group_affiliations_sync!
    ActivityPub::SynchronizeGroupAffiliationsWorker.perform_async(@account.id, group_affiliations_worker_options)
  end

  def enqueue_group_affiliations?
    return false unless @account.group?

    @account.affiliations_url.present? || inline_affiliations_collection.present?
  end

  def group_affiliations_worker_options
    collection = inline_affiliations_collection
    return {} if collection.nil?

    { 'collection' => native_json(collection) }
  end

  def native_json(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, nested), memo| memo[key.to_s] = native_json(nested) }
    when Array
      value.map { |nested| native_json(nested) }
    else
      value
    end
  end

  def normalized_affiliations_url
    valid_collection_uri(@json['affiliations']).presence&.to_s
  end

  def inline_affiliations_collection
    value = @json['affiliations']
    return unless value.is_a?(Hash)
    return unless equals_or_includes_any?(value['type'], ActivityPub::FetchGroupAffiliationsService::COLLECTION_TYPES)

    value
  end

  def deferred_inline_collection
    collection = inline_affiliations_collection
    native_json(collection) if collection
  end

  # A present affiliations value that is neither a collection nor a URI is
  # not a successful empty snapshot and must not be withdrawn as "removed".
  def deferred_affiliations_invalid?
    @options[:defer_group_affiliations] &&
      @account.group? &&
      @json['affiliations'].present? &&
      @account.affiliations_url.blank?
  end

  def withdraw_group_affiliations_cache!
    return if @account.group? && @json['affiliations'].present?
    return unless affiliation_cache_present?

    GroupAffiliation.transaction do
      @account.group_affiliations.delete_all
      @account.update_columns(affiliations_fetched_at: nil) if @account.affiliations_fetched_at.present?
    end
  ensure
    @account.association(:group_affiliations).reset
  end

  def affiliation_cache_present?
    @account.saved_change_to_affiliations_url? ||
      @account.affiliations_fetched_at.present? ||
      @account.group_affiliations.exists?
  end
end
