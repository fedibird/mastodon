# frozen_string_literal: true

module ExternalBridge
  module VisibilityMigration
    # Cache audit for this tree:
    # - CacheConcern#cache_collection only preloads. It stores nothing.
    # - REST status JSON is rendered per request. visibility_ex is not a shared cache.
    # - ActivityPub render_with_cache keys include status.cache_key, which changes
    #   when updated_at changes. Private rows are not distributable, so that cache
    #   is not a projection body. The migration still bumps updated_at.
    # - Rails.cache key "statuses/#{id}" is deleted by purge and account deletion.
    #   No writer was found. Delete that key per id anyway so a stale entry cannot
    #   survive. Do not delete processing, circle, or published Redis keys.
    # - No status.update distribution. An open WebUI keeps its copy until reload.
    # - Search stays non-indexable. The root Chewy strategy is :custom_sidekiq,
    #   which only remembers ids until the strategy is popped. This follow-up
    #   does not use that strategy. It deletes these ids in slices of SLICE and
    #   reads each bulk item, then a GET, before the checkpoint may advance.
    #   Success is a deleted item, or a response that names that document as
    #   missing. A missing index or alias, a proxy 404, and any other 404 stay
    #   incomplete.
    class CacheSync
      SLICE = 100
      DOCUMENT_MISSING_TYPE = 'document_missing_exception'

      class SearchFollowUpError < StandardError; end

      def self.invalidate!(status_ids)
        ids = Array(status_ids).map { |id| Integer(id) }.uniq.reject(&:zero?)
        return if ids.empty?

        ids.each { |id| Rails.cache.delete("statuses/#{id}") }
        drop_search_documents(ids)
      end

      def self.drop_search_documents(ids)
        return unless defined?(Chewy) && Chewy.enabled?

        assert_projection_ids!(ids)
        ids.each_slice(SLICE) do |slice|
          delete_slice!(slice)
        end
      end

      # A NotFound raised by the bulk call is the request itself (missing index,
      # missing alias, or a proxy). It is not proof that these documents are gone.
      def self.delete_slice!(slice)
        response = Chewy.client.bulk(refresh: true, body: bulk_body(slice))
        accept_bulk!(response, slice)
        slice.each { |id| assert_absent!(id) }
      rescue Elasticsearch::Transport::Transport::Errors::NotFound
        raise SearchFollowUpError, 'search delete failed'
      end
      private_class_method :delete_slice!

      def self.bulk_body(slice)
        index = StatusesIndex.index_name
        slice.map { |id| { delete: { _index: index, _id: id.to_s } } }
      end
      private_class_method :bulk_body

      def self.accept_bulk!(response, slice)
        items = bulk_items(response)
        raise SearchFollowUpError, 'search bulk response was incomplete' unless items.length == slice.length

        items.each do |item|
          action = item_value(item, 'delete') || {}
          raise SearchFollowUpError, 'search delete did not complete' unless delete_accepted?(action)
        end
      end
      private_class_method :accept_bulk!

      def self.bulk_items(response)
        return [] unless response.respond_to?(:[])

        Array(item_value(response, 'items'))
      end
      private_class_method :bulk_items

      def self.delete_accepted?(action)
        status = item_value(action, 'status').to_i
        result = item_value(action, 'result').to_s
        error = item_value(action, 'error')
        return true if status == 200 && result == 'deleted' && error.nil?
        return true if status == 404 && result == 'not_found' && document_missing_item?(error)

        false
      end
      private_class_method :delete_accepted?

      # No error object is the bulk-delete response for a missing document.
      # document_missing_exception is the only error type with that meaning.
      def self.document_missing_item?(error)
        return true if error.nil?

        item_value(error, 'type').to_s == DOCUMENT_MISSING_TYPE
      end
      private_class_method :document_missing_item?

      def self.assert_absent!(id)
        found = Chewy.client.get(index: StatusesIndex.index_name, id: id.to_s)
        raise SearchFollowUpError, "search document #{id} is still present" if found.present?
      rescue Elasticsearch::Transport::Transport::Errors::NotFound => e
        return if confirmed_absent?(e, id)

        raise SearchFollowUpError, 'search document absence was not confirmed'
      end
      private_class_method :assert_absent!

      # The transport client formats this as "[404] #{body}". Absence is the
      # document body with found:false for this id. Index errors and HTML do not parse to that.
      def self.confirmed_absent?(error, id)
        payload = json_object(error.message.to_s.sub(/\A\[\d+\]\s*/, ''))
        return false unless payload
        return false if item_value(payload, 'error').present?
        return false unless item_value(payload, 'found') == false

        item_value(payload, '_id').to_s == id.to_s
      end
      private_class_method :confirmed_absent?

      def self.json_object(text)
        parsed = JSON.parse(text)
        parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError, TypeError
        nil
      end
      private_class_method :json_object

      def self.assert_projection_ids!(ids)
        present = {}
        Status.unscoped.where(id: ids).pluck(:id, :visibility, :external_projection).each do |id, visibility, flag|
          present[id] = [visibility, flag]
        end
        marked = ExternalStatusProjection.where(status_id: ids).pluck(:status_id)
        ids.each do |id|
          next unless present.key?(id)

          visibility, flag = present[id]
          projection = flag == true || visibility.to_s == 'external' || visibility == Schema::EXTERNAL_VISIBILITY || marked.include?(id)
          raise SearchFollowUpError, "refusing to delete non-projection status #{id}" unless projection
        end
      end
      private_class_method :assert_projection_ids!

      def self.item_value(object, key)
        return object[key] if object.respond_to?(:key?) && object.key?(key)
        return object[key.to_sym] if object.respond_to?(:key?) && object.key?(key.to_sym)

        nil
      end
      private_class_method :item_value
    end
  end
end
