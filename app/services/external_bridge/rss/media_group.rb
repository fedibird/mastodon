# frozen_string_literal: true

module ExternalBridge
  module RSS
    # One media:group is one logical media. Nested media:group elements are
    # their own groups, not extra renditions of the parent. A parent's
    # variants are only its direct media:content, media:player, and
    # media:embed children. Sibling groups are never joined, even when a URL
    # matches. An un-namespaced group is not a group and is not entered.
    #
    # The group key is the sorted set of stored variant URLs. It is not the
    # document position and not a node object id. The same renditions keep
    # the same key when only the representative changes. Adding, dropping, or
    # replacing a stored URL changes the key. Two groups with the same URL
    # set share a key and still stay two frames.
    #
    # Selection, among variants that already passed URL, type, and
    # PlayerResolver checks: an explicit isDefault, then expression full
    # (omitted counts as full), then document order. sample and nonstop stay
    # in the last tier. The highest bitrate is not preferred.
    class MediaGroup
      VARIANT_KINDS = %w(image audio video embed).freeze
      MEDIUMS = %w(image audio video).freeze
      EXPRESSIONS = %w(full sample nonstop).freeze

      def self.collect(node, sink)
        new(node, sink).collect
      end

      def self.single(node, sink)
        return nil unless content?(node)

        new(node, sink).bare_candidate
      end

      def self.select(variants)
        eligible = Array(variants).select { |row| VARIANT_KINDS.include?(row['kind']) }
        return nil if eligible.empty?

        defaults = eligible.select { |row| row['is_default'] == true }
        pool = defaults.presence || full_tier(eligible).presence || eligible
        pool.min_by { |row| row['order'].to_i }
      end

      def self.window(variants, winner)
        return [] if winner.nil?
        return variants if variants.size <= Limits::MAX_GROUP_VARIANTS

        opened = variants.first(Limits::MAX_GROUP_VARIANTS)
        return opened if opened.any? { |row| row['order'] == winner['order'] }

        (variants.first(Limits::MAX_GROUP_VARIANTS - 1) + [winner]).sort_by { |row| row['order'].to_i }
      end

      def self.key_for(urls)
        body = urls.map(&:to_s).reject(&:empty?).uniq.sort.join("\n")
        Digest::SHA256.hexdigest("mrss-group:v1\n#{body}")
      end

      # Rebuild the persisted group from a whitelist. A key that does not
      # match the stored URLs is dropped. The outer candidate remains.
      def self.sanitize_stored(group)
        return nil unless group.is_a?(Hash)

        source = group.stringify_keys
        variants = Array(source['variants']).filter_map { |row| sanitize_variant(row) }.first(Limits::MAX_GROUP_VARIANTS)
        return nil if variants.empty?

        key = source['key'].to_s
        ordered = variants.sort_by { |row| row['order'] }
        return nil unless key == key_for(ordered.map { |row| row['url'] })

        { 'key' => key, 'variants' => ordered }
      end

      def self.content?(node)
        node&.name == 'content' && node.namespace&.href == XmlNames::MEDIA
      end

      def self.full_tier(eligible)
        eligible.select { |row| row['expression'].nil? || row['expression'] == 'full' }
      end

      def initialize(node, sink)
        @node = node
        @sink = sink
      end

      def collect
        return unless @sink.budget.take?
        return if @sink.depth >= Limits::MAX_GROUP_DEPTH

        @sink.depth += 1
        @sink.scope << @sink.allocate_id
        @entered = true
        variants, nested = walk_children
        emit_frame(variants)
        nested.each { |child| self.class.new(child, @sink).collect }
      ensure
        release if @entered
      end

      def bare_candidate
        variant = content_variant(@node)
        return nil if variant.nil?

        variant['order'] = 0
        frame_row(variant, [variant]).except('group')
      end

      private

      def release
        @sink.scope.pop
        @sink.depth -= 1
      end

      def walk_children
        variants = []
        seen = {}
        nested = []
        @node.element_children.each do |child|
          if group?(child)
            nested << child
            next
          end
          break unless @sink.budget.take?

          @sink.scan&.observe_facts(child)
          collect_child(child, variants, seen)
        end
        [variants, nested]
      end

      def collect_child(child, variants, seen)
        if MediaThumbnail.thumbnail?(child)
          add_thumbnail(child)
        elsif player?(child)
          push_variant(variants, seen, player_variant(child))
        elsif embed?(child)
          push_variant(variants, seen, embed_variant(child))
        elsif self.class.content?(child)
          push_variant(variants, seen, content_variant(child))
        end
      end

      def push_variant(variants, seen, variant)
        return if variant.nil?
        return if seen[variant['url']]

        seen[variant['url']] = true
        variant['order'] = variants.size
        variants << variant
      end

      def emit_frame(variants)
        winner = self.class.select(variants)
        return if winner.nil?

        kept = self.class.window(variants, winner)
        row = frame_row(winner, kept)
        stamp_frame!(row)
        @sink.raw << row
        @sink.posters << row['poster_url'] if row['kind'] == 'video' && row['poster_url'].present?
      end

      def frame_row(winner, kept)
        row = {
          'url' => winner['url'],
          'kind' => winner['kind'],
          'role' => winner['kind'] == 'embed' ? 'player' : 'attachment',
          'origin' => winner['origin'],
          'group' => {
            'key' => self.class.key_for(kept.map { |item| item['url'] }),
            'variants' => kept.map { |item| stored_variant(item) },
          },
        }
        copy_detail!(row, winner)
        row
      end

      def copy_detail!(row, winner)
        hint = MediaLocator.mime_hint(winner['mime'])
        row['mime_hint'] = hint if hint
        row['length_hint'] = winner['length_hint'] unless winner['length_hint'].nil?
        row['description'] = winner['description'] if winner['description'].present?
        return unless winner['kind'] == 'video' && winner['poster_url'].present?

        row['poster_url'] = winner['poster_url']
      end

      def stored_variant(variant)
        row = { 'url' => variant['url'], 'kind' => variant['kind'], 'order' => variant['order'] }
        row['mime'] = variant['mime'] if variant['mime'].present?
        row['medium'] = variant['medium'] if MEDIUMS.include?(variant['medium'])
        %w(width height bitrate length_hint).each do |key|
          row[key] = variant[key] unless variant[key].nil?
        end
        row['is_default'] = variant['is_default'] unless variant['is_default'].nil?
        row['expression'] = variant['expression'] if EXPRESSIONS.include?(variant['expression'])
        row
      end

      def stamp_frame!(row)
        return unless %w(video audio).include?(row['kind'])

        row['_group_path'] = @sink.scope.dup
      end

      def content_variant(node)
        reference = content_reference(node)
        return file_from(node, reference) if reference.present?

        child = node.element_children.find { |item| player?(item) || embed?(item) }
        return nil if child.nil?

        variant = player?(child) ? player_variant(child) : embed_variant(child)
        return nil if variant.nil?

        text = description_for(node)
        variant['description'] = text if text
        variant
      end

      def file_from(node, reference)
        absolute = MediaLocator.normalize(reference, @sink.base)
        return nil if absolute.blank?

        decision = MediaClassifier.decide(
          type: node['type'],
          medium: node['medium'],
          url: absolute,
          measures: { width: node['width'], height: node['height'], bitrate: node['bitrate'] }
        )
        return nil unless decision.status == :eligible

        file_variant(node, absolute, decision)
      end

      def file_variant(node, url, decision)
        variant = {
          'url' => url,
          'kind' => decision.kind,
          'origin' => 'media_rss',
          'mime' => decision.mime,
          'medium' => decision.medium,
          'width' => decision.width,
          'height' => decision.height,
          'bitrate' => decision.bitrate,
          'is_default' => MediaClassifier.flag(node['isDefault']),
          'expression' => MediaClassifier.expression(node['expression']),
          'length_hint' => MediaLocator.length_hint(node['fileSize']),
          'description' => description_for(node),
        }
        poster = content_poster(node)
        variant['poster_url'] = poster if decision.kind == 'video' && poster.present?
        variant.compact
      end

      def content_poster(node)
        thumb = node.element_children.find { |child| MediaThumbnail.thumbnail?(child) }
        MediaLocator.normalize(MediaThumbnail.reference(thumb), @sink.base)
      end

      # The url attribute wins, including when it is blank. Element text is
      # a URL only when the attribute was omitted and the content has no
      # child elements. Description and title text are not media URLs.
      def content_reference(node)
        attribute = node.attribute_with_ns('url', nil)
        return attribute.value if attribute
        return nil if node.element_children.any?

        node.text.to_s.strip
      end

      def player_variant(node)
        resolved = resolve_player(node.attribute_with_ns('url', nil)&.value, 'media_player')
        return nil if resolved.blank?

        embed_fields(resolved, 'media_player', node)
      end

      def embed_variant(node)
        attribute = node.attribute_with_ns('url', nil)
        return nil if attribute.nil?

        resolved = resolve_player(attribute.value, 'media_embed')
        return nil if resolved.blank?

        embed_fields(resolved, 'media_embed', node)
      end

      def embed_fields(url, origin, node)
        {
          'url' => url,
          'kind' => 'embed',
          'origin' => origin,
          'is_default' => MediaClassifier.flag(node['isDefault']),
          'expression' => MediaClassifier.expression(node['expression']),
        }
      end

      def resolve_player(url, origin)
        chosen = PlayerResolver.choose(@sink.article_url, [{ priority: 1, at: 0, origin: origin, urls: [url.to_s] }])
        chosen&.url
      end

      def add_thumbnail(node)
        url = MediaLocator.normalize(MediaThumbnail.reference(node), @sink.base)
        return if url.blank?

        @sink.raw << {
          'url' => url,
          'kind' => 'image',
          'role' => 'attachment',
          'origin' => 'media_thumbnail',
          '_scope' => 'group',
          '_group_id' => @sink.scope.last,
        }
      end

      def description_for(node)
        raw = node['description'].presence || description_text(node)
        MediaLocator.clean(raw)
      end

      def description_text(node)
        nested = node.element_children.find { |child| child.name == 'description' && media_or_plain?(child) }
        nested&.text
      end

      def media_or_plain?(node)
        href = node.namespace&.href
        href.nil? || href == XmlNames::MEDIA
      end

      def group?(node)
        node.name == 'group' && node.namespace&.href == XmlNames::MEDIA
      end

      def player?(node)
        node.name == 'player' && node.namespace&.href == XmlNames::MEDIA
      end

      def embed?(node)
        node.name == 'embed' && node.namespace&.href == XmlNames::MEDIA
      end

      class << self
        private

        def sanitize_variant(row)
          return nil unless row.is_a?(Hash)

          source = row.stringify_keys
          kind = source['kind'].to_s
          url = source['url'].to_s
          order = source['order']
          return nil unless VARIANT_KINDS.include?(kind)
          return nil unless acceptable_url?(kind, url)
          return nil unless order.is_a?(Integer) && order >= 0 && order <= Limits::MAX_GROUP_SCAN

          build_variant(source, kind, url, order)
        end

        def build_variant(source, kind, url, order)
          row = { 'url' => url, 'kind' => kind, 'order' => order }
          mime = MediaLocator.mime_hint(source['mime'])
          row['mime'] = mime if mime
          row['medium'] = source['medium'] if MEDIUMS.include?(source['medium'].to_s)
          copy_numbers!(row, source)
          row['is_default'] = source['is_default'] if source['is_default'] == true || source['is_default'] == false
          row['expression'] = source['expression'] if EXPRESSIONS.include?(source['expression'].to_s)
          row
        end

        def copy_numbers!(row, source)
          %w(width height).each do |key|
            number = source[key]
            row[key] = number if number.is_a?(Integer) && number >= 0 && number <= MediaClassifier::MAX_DIMENSION
          end
          bitrate = source['bitrate']
          row['bitrate'] = bitrate if bitrate.is_a?(Integer) && bitrate.positive? && bitrate <= MediaClassifier::MAX_BITRATE
          length = source['length_hint']
          row['length_hint'] = length if length.is_a?(Integer) && !length.negative? && length <= 1_099_511_627_776
        end

        def acceptable_url?(kind, url)
          return false if url.blank? || url.bytesize > Limits::MAX_KEY_BYTES || url.match?(/[\s\\<>"]/)
          return false unless url.match?(%r{\Ahttps://}i)
          return true if kind == 'embed'

          MediaURL.normalize(url) == url
        end
      end

      # Walk state for one item. The scope ids exist only while thumbnails
      # are bound. They are not stored and are not the group key.
      class Sink
        attr_reader :raw, :posters, :base, :article_url, :scope, :budget, :scan
        attr_accessor :depth

        def initialize(**parts)
          @raw = parts.fetch(:raw)
          @posters = parts.fetch(:posters)
          @base = parts[:base]
          @article_url = parts[:article_url]
          @scope = parts.fetch(:scope)
          @budget = parts.fetch(:budget)
          @scan = parts[:scan]
          @depth = 0
          @serial = 0
        end

        def allocate_id
          @serial += 1
        end
      end

      class Budget
        def initialize(limit)
          @left = limit
        end

        def take?
          return false if @left <= 0

          @left -= 1
          true
        end
      end
    end
  end
end
