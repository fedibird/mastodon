# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Icon
      # Fetches, validates, and stores the shared icon of one external source.
      #
      # The job never touches articles, subscriptions, or projections, and no
      # failure here is raised to the feed refresh. A bad image, a private
      # address, a timeout, or a deleted source ends in a recorded outcome and
      # a backoff; the previous icon, if any, stays in place.
      #
      # One run per source at a time: a transaction-scoped PostgreSQL advisory
      # lock (its own class, separate from the feed refresh lock) skips a
      # second concurrent run, and the Sidekiq uniqueness lock keeps duplicates
      # out of the queue.
      #
      # The lock is taken with pg_try_advisory_xact_lock inside one explicit
      # transaction that spans the run. Fedibird supports PgBouncer transaction
      # pooling, where two autocommit statements may reach different server
      # backends: a session lock (pg_try_advisory_lock / pg_advisory_unlock)
      # could then stay held on a backend nobody unlocks, or the unlock could
      # run elsewhere and leave the lock behind. A transaction pins one backend
      # and the lock is released by COMMIT, ROLLBACK, or the connection ending,
      # never by a second statement. Because the transaction is open during the
      # downloads, the run has a deadline (Limits::ICON_RUN_DEADLINE), writes
      # to the source row are made only at the end so no row lock is held while
      # waiting on the network, and a failure rolls everything back.
      class RefreshSource
        LOCK_CLASS = 810_532

        # A stored icon whose address now answers like this is looked up again
        # from scratch. Anything else (timeout, rate limit, 5xx) keeps the
        # stored copy and only backs off.
        REDISCOVER_CODES = %w(
          http_404 http_410 icon_bad_content_type icon_empty icon_unrecognized_image
          icon_type_mismatch icon_dimensions icon_too_small icon_unsuitable_shape
        ).freeze

        def call(source_id, force: false)
          started = RefreshLog.now
          @fields = {}
          @deadline = started + Limits::ICON_RUN_DEADLINE
          @discovered_hints = nil
          outcome = run(source_id, force)
          record(source_id, outcome, started)
        rescue StandardError => e
          record(source_id, 'unexpected_error', started || RefreshLog.now, error_class: e.class)
          raise
        end

        private

        def run(source_id, force)
          return 'skipped_feature_disabled' unless Feature.enabled?

          with_lock(source_id) { refresh_locked(source_id, force) }
        end

        def record(source_id, outcome, started, extra = {})
          fields = { source_id: source_id, outcome: outcome }.merge(@fields).merge(extra)
          fields[:elapsed_ms] = RefreshLog.elapsed_ms(started)
          RefreshLog.emit('icon', fields)
          outcome
        end

        def refresh_locked(source_id, force)
          source = ExternalSource.find_by(id: source_id)
          return 'skipped_source_missing' if source.nil?
          return 'skipped_no_subscriptions' unless source.external_subscriptions.active.exists?
          return 'skipped_not_due' unless force || Schedule.due?(source)

          stored_icon?(source) ? revalidate(source) : discover(source)
        end

        def stored_icon?(source)
          Delivery.stored?(source) && source.icon_remote_url.present?
        end

        def revalidate(source)
          result = ImageFetch.new.call(source.icon_remote_url, etag: source.icon_etag, last_modified: source.icon_last_modified)
          return mark_unchanged(source, result, 'icon_not_modified') if result.not_modified
          return mark_unchanged(source, result, 'icon_unchanged') if result.fingerprint == source.icon_fingerprint

          store(source, Candidates::Candidate.new(url: result.final_url, origin: source.icon_origin), result)
        rescue Error => e
          return discover(source) if REDISCOVER_CODES.include?(e.code)

          mark_failed(source, e.code)
        end

        def discover(source)
          ensure_hints(source)
          candidates = Candidates.new(source)
          last_code = nil
          attempts = 0

          candidates.each do |candidate|
            break if attempts >= Limits::ICON_CANDIDATES

            if RefreshLog.now > @deadline
              last_code = 'icon_deadline'
              break
            end

            attempts += 1
            @fields[:candidates] = attempts
            begin
              result = ImageFetch.new.call(candidate.url)
            rescue Error => e
              last_code = e.code
              next
            end
            return keep_or_store(source, candidate, result)
          end

          mark_failed(source, last_code || 'icon_no_candidate')
        end

        # A source that predates this feature has no recorded hints. Reading the
        # feed once here gives it the same ordering a new source gets, instead
        # of a favicon first and a replacement later. A failure is not
        # recorded, so the next attempt asks again.
        def ensure_hints(source)
          return unless source.icon_hints.nil?

          response = HttpClient.get(source.canonical_key)
          hints = response.code.between?(200, 299) ? Parser.parse!(response.body).icon_hints : []
          @discovered_hints = hints
          source.icon_hints = hints
        rescue Error
          source.icon_hints = []
        end

        # The hints are written together with the outcome, so the source row is
        # not locked while the candidates are downloaded.
        def hint_attributes
          @discovered_hints.nil? ? {} : { icon_hints: @discovered_hints }
        end

        def keep_or_store(source, candidate, result)
          return mark_unchanged(source, result, 'icon_unchanged', origin: candidate.origin) if stored_icon?(source) && source.icon_fingerprint == result.fingerprint

          store(source, candidate, result)
        end

        def store(source, candidate, result)
          outcome = nil
          ApplicationRecord.transaction(requires_new: true) do
            locked = ExternalSource.lock.find_by(id: source.id)
            if locked.nil?
              outcome = 'skipped_source_missing'
              next
            end

            outcome = Delivery.stored?(locked) ? 'icon_replaced' : 'icon_stored'
            write_icon!(locked, candidate, result)
          end
          outcome
        rescue StandardError => e
          raise unless storage_error?(e)

          mark_failed(source, 'icon_storage_failed')
        end

        def write_icon!(locked, candidate, result)
          Tempfile.create(['feed-icon', ".#{ImageFetch::EXTENSIONS.fetch(result.type)}"], binmode: true) do |file|
            file.write(result.body)
            file.flush
            file.rewind
            locked.icon = file
            locked.assign_attributes(
              icon_fingerprint: result.fingerprint,
              icon_remote_url: result.final_url,
              icon_origin: candidate.origin.to_s.first(32),
              icon_etag: result.etag,
              icon_last_modified: result.last_modified,
              icon_checked_at: Time.current,
              icon_next_check_at: Schedule.success_at,
              icon_failure_count: 0,
              icon_error_code: nil,
              **hint_attributes
            )
            locked.save!
          end
        end

        def storage_error?(error)
          error.is_a?(ActiveRecord::ActiveRecordError) ||
            error.is_a?(Paperclip::Error) ||
            error.is_a?(Mastodon::DimensionsValidationError) ||
            error.is_a?(Terrapin::CommandLineError) ||
            error.is_a?(SystemCallError) ||
            error.is_a?(IOError)
        end

        def mark_unchanged(source, result, outcome, origin: nil)
          now = Time.current
          attributes = {
            icon_checked_at: now,
            icon_next_check_at: Schedule.success_at(now),
            icon_failure_count: 0,
            icon_error_code: nil,
          }.merge(hint_attributes)
          # The address that answered (after validated redirects) is what the
          # next check must ask, otherwise a moved icon is requested through
          # the old address forever. A 304 carries no new validators, so the
          # stored ones, which that address just accepted, are kept.
          attributes[:icon_remote_url] = result.final_url if result.final_url.present?
          attributes[:icon_origin] = origin.to_s.first(32) if origin.present?
          unless result.not_modified
            attributes[:icon_etag] = result.etag
            attributes[:icon_last_modified] = result.last_modified
          end
          ExternalSource.where(id: source.id).update_all(attributes)
          outcome
        end

        def mark_failed(source, code)
          now = Time.current
          failures = source.icon_failure_count.to_i + 1
          ExternalSource.where(id: source.id).update_all(
            icon_checked_at: now,
            icon_next_check_at: Schedule.failure_at(failures, now),
            icon_failure_count: failures,
            icon_error_code: code.to_s.first(64),
            **hint_attributes
          )
          @fields[:error_code] = RefreshLog.code(code)
          code.to_s == 'icon_no_candidate' ? 'icon_not_found' : 'icon_failed'
        end

        def with_lock(source_id)
          ApplicationRecord.transaction do
            sql = ActiveRecord::Base.sanitize_sql_array(["SELECT pg_try_advisory_xact_lock(#{LOCK_CLASS}, ?)", source_id.to_i])
            locked = ApplicationRecord.connection.select_value(sql)
            next 'skipped_lock_busy' unless locked == true || locked.to_s == 't'

            yield
          end
        end
      end
    end
  end
end
