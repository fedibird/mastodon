# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Resolves a file to the article URL digest while a generation swap is
      # open. The new row keeps url_digest incoming:{old id} until every
      # projection has moved. logical_digest stores the article digest those
      # projections must still match.
      class GenerationMap
        def self.incoming_digest(asset_id)
          "incoming:#{asset_id.to_i}"
        end

        def self.checkpoint?(digest)
          text = digest.to_s
          text.start_with?('incoming:', 'superseded:')
        end

        def self.display_digests(asset)
          return [] if asset.nil?

          digests = []
          raw = asset.url_digest.to_s
          digests << raw unless checkpoint?(raw)
          digests << asset.logical_digest if asset.logical_digest.present? && !checkpoint?(asset.logical_digest)
          digests.concat(predecessor_digests(raw)) if raw.start_with?('incoming:') && asset.logical_digest.blank?
          digests.uniq
        end

        def self.generation_key(asset)
          return if asset.nil?

          raw = asset.url_digest.to_s
          return raw.delete_prefix('incoming:').to_i if raw.start_with?('incoming:')
          return if checkpoint?(raw)

          asset.id
        end

        def self.successor_for(asset)
          return if asset.nil? || checkpoint?(asset.url_digest)

          ExternalMediaAsset.find_by(url_digest: incoming_digest(asset.id))
        end

        def self.predecessor_digests(raw)
          predecessor = ExternalMediaAsset.find_by(id: raw.delete_prefix('incoming:').to_i)
          return [] if predecessor.nil?

          [predecessor.url_digest, predecessor.logical_digest].compact.reject { |digest| checkpoint?(digest) }
        end

        private_class_method :predecessor_digests
      end
    end
  end
end
