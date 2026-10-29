# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # One projection link per shared asset. An article image and an embed
      # poster may name that file. The gallery candidate owns the link kind
      # and ALT. The poster is still found later by its URL.
      class SharedFile
        def self.collapse(pairs)
          new(pairs).collapse
        end

        def initialize(pairs)
          @pairs = pairs
        end

        def collapse
          chosen = {}
          order = []
          @pairs.each do |candidate, asset|
            key = GenerationMap.generation_key(asset) || asset.id
            if chosen[key]
              chosen[key][0] = gallery_candidate(chosen[key][0], candidate)
            else
              chosen[key] = [candidate, asset]
              order << key
            end
          end
          order.map { |key| chosen[key] }
        end

        private

        def gallery_candidate(current, extra)
          return extra if current['role'] == 'poster' && extra['role'] != 'poster'

          current
        end
      end
    end
  end
end
