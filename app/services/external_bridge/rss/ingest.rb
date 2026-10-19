# frozen_string_literal: true

module ExternalBridge
  module RSS
    class Ingest
      def apply_public!(source, feed, response)
        written = []
        ApplicationRecord.transaction do
          source.update!(
            title: feed.title.presence || source.title,
            site_url: feed.site_url.presence || source.site_url,
            etag: response.etag,
            last_modified: response.last_modified,
            fetched_at: Time.current,
            checked_at: Time.current
          )
          actor = upsert_actor!(source, feed)
          written = feed.items.map { |item| upsert_resource!(source, actor, item) }
        end
        written
      end

      def find_or_create_source!(feed, canonical_key)
        existing = ExternalSource.find_by(canonical_key: canonical_key)
        return existing if existing

        ExternalSource.create!(protocol: feed.protocol, canonical_key: canonical_key, title: feed.title, site_url: feed.site_url)
      rescue ActiveRecord::RecordNotUnique
        ExternalSource.find_by!(canonical_key: canonical_key)
      end

      private

      def upsert_actor!(source, feed)
        actor = ExternalActor.find_or_initialize_by(protocol: source.protocol, native_id: source.canonical_key)
        actor.display_name = feed.title.presence || actor.display_name
        actor.profile_url = feed.site_url.presence || actor.profile_url
        actor.save!
        actor
      end

      def upsert_resource!(source, actor, item)
        key = resource_key(source, item.key)
        resource = ExternalResource.find_or_initialize_by(protocol: source.protocol, canonical_key: key)
        digest = Digest::SHA256.hexdigest([item.title, item.body, item.canonical_url].join("\n"))
        resource.external_source = source
        resource.external_actor = actor
        resource.revision = digest
        resource.canonical_url = item.canonical_url
        resource.title = item.title
        resource.body = item.body
        resource.byline = item.byline
        resource.body_digest = digest
        resource.published_at = item.published_at
        resource.truncated = item.truncated
        resource.fetched_at = Time.current
        resource.source_deleted_at = nil
        resource.save!
        resource
      end

      def resource_key(source, item_key)
        "feed:#{source.canonical_key}\nitem:#{item_key}"
      end
    end
  end
end
