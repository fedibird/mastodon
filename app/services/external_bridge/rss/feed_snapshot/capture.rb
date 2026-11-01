# frozen_string_literal: true

module ExternalBridge
  module RSS
    module FeedSnapshot
      # Stores one fetched body and imports its history page before returning.
      #
      # The history page is the same ordering Subscribe already shows:
      # published_at DESC NULLS FIRST, then later document position first.
      # It is at most Limits::MAX_ITEMS keyed items. The rest stay in the
      # body for Drain. Validators move in the same transaction as the body
      # and that page, so a crash does not 304 away a body we did not keep
      # and does not publish fetched_at before the page exists.
      #
      # A keyed item with no guid, atom id, or link is not a position.
      # Duplicate keys stay two positions and upsert one resource; the later
      # document position wins because positions are applied in ascending
      # order. Date order is not a reason to stop.
      class Capture
        def call(response:, canonical_key:, source: nil)
          @body = response.body.to_s
          @response = response
          @index = Parser.index!(@body)
          raise Error, :snapshot_item_limit if @index.keyed_items.size > Limits::SNAPSHOT_MAX_ITEMS

          @positions = history_positions(@index.keyed_items)
          @items = @positions.empty? ? [] : Parser.parse_positions!(@body, @positions)
          @feed = feed_for(@index)
          resolved = resolve_source(canonical_key, source, @feed)
          # Drop only disposable text before taking the capacity lock.
          # The hard check runs again inside that lock, with the insert.
          Purge.call
          store!(resolved)
        end

        private

        def store!(resolved)
          attempts = 0
          begin
            attempts += 1
            insert_generation!(resolved)
          rescue ActiveRecord::RecordNotUnique
            retry if attempts < 3

            raise
          end
        end

        def insert_generation!(resolved)
          ApplicationRecord.transaction do
            lock_capacity!
            raise Error, :snapshot_capacity unless ExternalFeedSnapshot.room_for?(@body.bytesize)

            locked = ExternalSource.lock.find(resolved.id)
            ingest = Ingest.new
            ingest.hold_feed_lock(locked.canonical_key)
            raise Error, :snapshot_backlog if locked.external_feed_snapshots.open.count >= Limits::SNAPSHOT_OPEN_LIMIT

            ingest.assign_channel!(locked, @feed, @response)
            ingest.ensure_actor!(locked, @feed)
            snapshot = insert_snapshot!(locked)
            # Same rule as Drain#next_snapshot. A failed remainder is not
            # open, but its items have not been applied. Writing this
            # generation's history now would let a later Retry of the older
            # body overwrite those rows.
            import_history!(ingest, locked, snapshot) unless older_unfinished?(locked, snapshot)
            ingest.recompute_activitypub!(locked)
            snapshot
          end
        end

        # One global transaction lock for the byte cap. Check and insert of
        # every source share it, so two captures cannot both pass room_for?.
        def lock_capacity!
          ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{Limits::SNAPSHOT_CAPACITY_LOCK})")
        end

        def insert_snapshot!(source)
          generation = source.external_feed_snapshots.maximum(:generation).to_i + 1
          source.external_feed_snapshots.create!(
            generation: generation,
            state: 'pending',
            etag: @response.etag,
            last_modified: @response.last_modified,
            body: @body,
            byte_size: @body.bytesize,
            item_count: @index.keyed_items.size,
            next_index: 0,
            history_positions: @positions
          )
        end

        def older_unfinished?(source, snapshot)
          source.external_feed_snapshots.where('generation < ?', snapshot.generation).where(
            "state IN ('pending', 'draining') OR (state = 'failed' AND next_index < item_count)"
          ).exists?
        end

        def import_history!(ingest, source, snapshot)
          by_position = @positions.zip(@items).to_h
          @positions.sort.each do |position|
            item = by_position[position]
            next if item.nil?

            ingest.upsert_item!(source, item, lock: false)
          end
          finish_history!(snapshot, snapshot.item_count)
        end

        def finish_history!(snapshot, item_count)
          now = Time.current
          if history_covers_all?(snapshot.history_position_list, item_count)
            snapshot.update!(state: 'complete', next_index: item_count, history_applied_at: now, completed_at: now)
          else
            snapshot.update!(history_applied_at: now)
          end
        end

        def history_covers_all?(positions, item_count)
          positions.sort == (0...item_count).to_a
        end

        def resolve_source(canonical_key, source, feed)
          return source if source&.canonical_key == canonical_key

          Ingest.new.find_or_create_source!(feed, canonical_key)
        end

        def feed_for(index)
          Feed.new(
            protocol: index.protocol,
            title: index.title,
            site_url: index.site_url,
            items: [],
            icon_hints: index.icon_hints,
            activitypub_hint: index.activitypub_hint,
            activitypub_generator_hint: index.activitypub_generator_hint
          )
        end

        # NULLS FIRST, then newer instants, then a later document position.
        # That is PostgreSQL's ORDER BY published_at DESC, id DESC once rows
        # are inserted in ascending position among this page. Ties across a
        # later tail insert can differ by id; the continued drain does not
        # use this page as its stop condition.
        def history_positions(entries)
          ranked = entries.each_index.sort { |left, right| compare_entry(entries[left], left, entries[right], right) }
          ranked.first(Limits::MAX_ITEMS)
        end

        def compare_entry(left_entry, left_pos, right_entry, right_pos)
          left_time = left_entry.published_at
          right_time = right_entry.published_at
          if left_time.nil? && right_time.nil?
            right_pos <=> left_pos
          elsif left_time.nil?
            -1
          elsif right_time.nil?
            1
          else
            compared = right_time <=> left_time
            compared.zero? ? right_pos <=> left_pos : compared
          end
        end
      end
    end
  end
end
