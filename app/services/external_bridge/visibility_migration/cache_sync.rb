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
    # - Search stays non-indexable. Touch only these ids, and only to drop a document.
    class CacheSync
      def self.invalidate!(status_ids)
        ids = Array(status_ids).map { |id| Integer(id) }.uniq.reject(&:zero?)
        return if ids.empty?

        ids.each { |id| Rails.cache.delete("statuses/#{id}") }
        drop_search_documents(ids)
      end

      def self.drop_search_documents(ids)
        return unless defined?(Chewy) && Chewy.enabled?

        Chewy.strategy.current.update(StatusesIndex, ids)
      end
      private_class_method :drop_search_documents
    end
  end
end
