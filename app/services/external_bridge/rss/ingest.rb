# frozen_string_literal: true

module ExternalBridge
  module RSS
    class Ingest
      def write_public!(feed, canonical_key, response)
        ApplicationRecord.transaction do
          with_feed_lock(canonical_key)
          source = find_or_create_source!(feed, canonical_key)
          [source, apply_public!(source, feed, response)]
        end
      end

      def apply_public!(source, feed, response)
        written = []
        ApplicationRecord.transaction do
          with_feed_lock(source.canonical_key)
          source.update!(
            title: feed.title.presence || source.title,
            site_url: feed.site_url.presence || source.site_url,
            etag: response.etag,
            last_modified: response.last_modified,
            fetched_at: Time.current,
            checked_at: Time.current,
            **icon_hint_attributes(source, feed)
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

      # The feed-declared icon candidates ride along with the public write so
      # the icon job never has to fetch the feed again. A changed declaration
      # makes the icon due again, but at most once an hour, so a feed that
      # rewrites its icon URL on every request cannot cause a download per poll.
      def icon_hint_attributes(source, feed)
        hints = feed.icon_hints
        return {} if source.icon_hints == hints

        attributes = { icon_hints: hints }
        recently_checked = source.icon_checked_at.present? && source.icon_checked_at > 1.hour.ago
        attributes[:icon_next_check_at] = nil if !source.icon_hints.nil? && !recently_checked
        attributes
      end

      def upsert_actor!(source, feed)
        save_once(ExternalActor, protocol: source.protocol, native_id: source.canonical_key) do |actor|
          actor.display_name = feed.title.presence || actor.display_name
          actor.profile_url = feed.site_url.presence || actor.profile_url
        end
      end

      def upsert_resource!(source, actor, item)
        key = resource_key(source, item.key)
        digest = Digest::SHA256.hexdigest([item.title, item.body, item.canonical_url].join("\n"))
        save_once(ExternalResource, protocol: source.protocol, canonical_key: key) do |resource|
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
        end
      end

      # A concurrent insert can win the unique key between find and save.
      # The retry loads that row and applies the same public attributes.
      def save_once(model, **identity)
        attempts = 0
        begin
          attempts += 1
          ApplicationRecord.transaction(requires_new: true) do
            record = model.find_or_initialize_by(identity)
            yield record
            record.save!
            record
          end
        rescue ActiveRecord::RecordNotUnique
          raise if attempts >= 2

          retry
        end
      end

      # Literal keys stay readable. Oversized guid/id values are SHA256 of
      # the original feed key and the original item id. The digest prefix
      # cannot collide with a literal `feed:` key. Two different ids merge
      # only if SHA256 itself collides.
      def resource_key(source, item_key)
        literal = "feed:#{source.canonical_key}\nitem:#{item_key}"
        return literal if literal.bytesize <= Limits::MAX_RESOURCE_KEY_BYTES

        feed_digest = Digest::SHA256.hexdigest(source.canonical_key.to_s)
        item_digest = Digest::SHA256.hexdigest(item_key.to_s)
        "digest:v1:#{feed_digest}:#{item_digest}"
      end

      def with_feed_lock(canonical)
        hi, lo = Digest::SHA256.digest(canonical.to_s).unpack('l>l>')
        sql = ActiveRecord::Base.sanitize_sql_array(['SELECT pg_advisory_xact_lock(?, ?)', hi.to_i, lo.to_i])
        ActiveRecord::Base.connection.execute(sql)
      end
    end
  end
end
