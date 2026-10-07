# frozen_string_literal: true

module ActivityPub::ProcessAccountAffiliations
  private

  def assign_group_affiliations_url!
    @account.affiliations_url = @account.group? ? normalized_affiliations_url : nil
  end

  def check_group_affiliations!
    if enqueue_group_affiliations?
      ActivityPub::SynchronizeGroupAffiliationsWorker.perform_async(@account.id, group_affiliations_worker_options)
    else
      withdraw_group_affiliations_cache!
    end
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
