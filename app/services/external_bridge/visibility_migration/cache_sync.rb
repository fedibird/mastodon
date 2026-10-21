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
    #   does not use that strategy. It deletes these ids and reads the bulk
    #   response before the checkpoint may advance.
    class CacheSync
      SLICE = 100

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

      def self.delete_slice!(slice)
        response = Chewy.client.bulk(refresh: true, body: bulk_body(slice))
        accept_bulk!(response, slice)
        slice.each { |id| assert_absent!(id) }
      rescue Elasticsearch::Transport::Transport::Errors::NotFound => e
        raise SearchFollowUpError, 'search delete failed' unless index_missing?(e)

        nil
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
        return true if status == 404 && result == 'not_found' && not_found_error?(error)

        false
      end
      private_class_method :delete_accepted?

      def self.not_found_error?(error)
        return true if error.nil?

        type = error.respond_to?(:[]) ? (item_value(error, 'type') || error).to_s : error.to_s
        type.include?('not_found')
      end
      private_class_method :not_found_error?

      def self.assert_absent!(id)
        found = Chewy.client.get(index: StatusesIndex.index_name, id: id.to_s)
        raise SearchFollowUpError, "search document #{id} is still present" if found.present?
      rescue Elasticsearch::Transport::Transport::Errors::NotFound => e
        raise SearchFollowUpError, 'search index disappeared after delete' if index_missing?(e)

        nil
      end
      private_class_method :assert_absent!

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

      def self.index_missing?(error)
        error.message.include?('index_not_found_exception')
      end
      private_class_method :index_missing?

      def self.item_value(object, key)
        return object[key] if object.respond_to?(:key?) && object.key?(key)
        return object[key.to_sym] if object.respond_to?(:key?) && object.key?(key.to_sym)

        nil
      end
      private_class_method :item_value
    end
  end
end
