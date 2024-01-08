# frozen_string_literal: true

class ActivityPub::FetchRemoteStatusService < BaseService
  include JsonLdHelper

  # Should be called when uri has already been checked for locality
  def call(uri, id: true, prefetched_body: nil, on_behalf_of: nil)
    @json = begin
      if prefetched_body.nil?
        fetch_resource(uri, id, on_behalf_of)
      else
        body_to_json(prefetched_body, compare_id: id ? uri : nil)
      end
    end

    return if !(supported_context? && expected_type?) || actor_id.nil? || !trustworthy_attribution?(@json['id'], actor_id)

    actor = ActivityPub::TagManager.instance.uri_to_resource(actor_id, Account)
    actor = ActivityPub::FetchRemoteAccountService.new.call(actor_id, id: true) if actor.nil? || needs_update?(actor)

    return if actor.nil? || actor.suspended?

    ActivityPub::Activity.factory(activity_json, actor, delivery: false).perform
  end

  private

  def activity_json
    { 'type' => 'Create', 'actor' => actor_id, 'object' => @json }
  end

  def actor_id
    value_or_id(first_of_value(@json['attributedTo']))
  end

  def trustworthy_attribution?(uri, attributed_to)
    return false if uri.nil? || attributed_to.nil?
    Addressable::URI.parse(uri).normalized_host.casecmp(Addressable::URI.parse(attributed_to).normalized_host).zero?
  end

  def supported_context?
    super(@json)
  end

  def expected_type?
    equals_or_includes_any?(@json['type'], ActivityPub::Activity::Create::SUPPORTED_TYPES + ActivityPub::Activity::Create::CONVERTED_TYPES)
  end

  def needs_update?(actor)
    actor.possibly_stale?
  end
end
