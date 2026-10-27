# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Deletes one prepared subscriber file, and only the file named by an
      # external_media_repoint_stages row. The prepare lease must have
      # lapsed, the row must be due, no projection link may point at the
      # file, and the account must still match. The status matches when it
      # is unchanged, or when purge has nullified it and that status row is
      # gone. A failure keeps the stage, records a code, and moves
      # available_at forward. After the attempt budget it stays retained.
      # A claim that dies is the same budget: once claimed_until has passed
      # and attempt_count is already at the limit, the row becomes retained
      # with failure_code claim_expired. Paperclip destroy removes the stored
      # object. This class does not compute a storage path or remove a directory.
      class PreparedRelease
        def self.release!(stage_id, token: nil)
          new(stage_id, token).release!
        end

        def self.reclaim_expired!(projection_id:, asset_id:)
          retain_exhausted!(MediaGc::BATCH, projection_id: projection_id, asset_id: asset_id)
          claim_due!(MediaGc::BATCH, projection_id: projection_id, asset_id: asset_id).each do |stage_id, token|
            release!(stage_id, token: token)
          end
        end

        # Retains claims whose lease died at the attempt budget, then claims
        # a bounded set of due stages and releases those claims. more is true
        # only when another exhausted or due row was already waiting behind
        # this batch. A row that fails is no longer due, so it cannot keep
        # the worker on a one-second loop.
        def self.sweep_expired!(limit:)
          exhausted = retain_exhausted!(limit)
          waiting = due_ids(limit + 1)
          claim_due!(limit).each { |stage_id, token| release!(stage_id, token: token) }
          { more: waiting.size > limit || exhausted[:more] }
        end

        def self.expired?
          counts = recovery_counts
          counts[:due].positive? || counts[:exhausted].positive?
        end

        # Counts for the media GC scheduler. diagnose does not delete a file.
        def self.recovery_counts
          quoted = connection.quote(Time.current)
          sql = <<~SQL.squish
            SELECT
              COUNT(*) FILTER (WHERE #{due_sql(quoted)}) AS due,
              COUNT(*) FILTER (WHERE #{exhausted_sql(quoted)}) AS exhausted,
              COUNT(*) FILTER (WHERE state = 'retained') AS retained,
              COUNT(*) FILTER (WHERE state = 'retained' AND failure_code = 'claim_expired') AS claim_expired
            FROM external_media_repoint_stages
          SQL
          row = connection.select_one(sql) || {}
          {
            due: row['due'].to_i,
            exhausted: row['exhausted'].to_i,
            retained: row['retained'].to_i,
            claim_expired: row['claim_expired'].to_i,
          }
        end

        # Saves the copied attachment and its stage in one transaction. A
        # committed attachment from this path has a stage. A kill before that
        # commit leaves no row. Paperclip may already have written the bytes;
        # those bytes have no row, and this class does not search for them.
        def self.prepare!(asset_id:, projection_id:, account_id:, status_id:)
          ApplicationRecord.transaction(requires_new: true) do
            copied = yield
            lease_until = Limits::MEDIA_REPOINT_PREPARE_LEASE.from_now
            stage = ExternalMediaRepointStage.create!(
              media_attachment_id: copied.id,
              external_media_asset_id: asset_id,
              external_status_projection_id: projection_id,
              account_id: account_id,
              status_id: status_id,
              lease_until: lease_until,
              available_at: lease_until
            )
            [copied, stage]
          end
        end

        # The worker that created the stage is abandoning it. Expiring the
        # lease is the explicit hand-off. The same checks then run.
        def self.abandon!(stage)
          return if stage.nil?

          now = Time.current
          ExternalMediaRepointStage.where(id: stage.id).update_all(
            state: 'pending',
            lease_until: now,
            available_at: now,
            claim_token: nil,
            claimed_until: nil,
            updated_at: now
          )
          release!(stage.id)
        end

        def self.due_ids(limit, projection_id: nil, asset_id: nil)
          quoted = connection.quote(Time.current)
          sql = <<~SQL.squish
            SELECT id FROM external_media_repoint_stages
            WHERE #{due_sql(quoted, projection_id: projection_id, asset_id: asset_id)}
            ORDER BY available_at, id
            LIMIT #{limit.to_i}
          SQL
          connection.select_values(sql).map(&:to_i)
        end
        private_class_method :due_ids

        def self.claim_due!(limit, projection_id: nil, asset_id: nil)
          now = Time.current
          token = SecureRandom.hex(8)
          quoted = connection.quote(now)
          sql = <<~SQL.squish
            WITH picked AS (
              SELECT id FROM external_media_repoint_stages
              WHERE #{due_sql(quoted, projection_id: projection_id, asset_id: asset_id)}
              ORDER BY available_at, id
              LIMIT #{limit.to_i}
              FOR UPDATE SKIP LOCKED
            )
            UPDATE external_media_repoint_stages AS stages
            SET claim_token = #{connection.quote(token)},
                claimed_until = #{connection.quote(now + MediaGc::LEASE)},
                attempt_count = stages.attempt_count + 1,
                updated_at = #{quoted}
            FROM picked
            WHERE stages.id = picked.id
            RETURNING stages.id
          SQL
          ApplicationRecord.transaction do
            connection.exec_query(sql).rows.map { |row| [row[0].to_i, token] }
          end
        end
        private_class_method :claim_due!

        def self.retain_exhausted!(limit, projection_id: nil, asset_id: nil)
          waiting = exhausted_ids(limit + 1, projection_id: projection_id, asset_id: asset_id)
          retained = retain_ids!(waiting.first(limit))
          if retained.any?
            Rails.logger.info(
              "[ExternalBridge::RSS] media prepare claim expired retained=#{retained.size} stage_ids=#{retained.join(',')}"
            )
          end
          { count: retained.size, more: waiting.size > limit }
        end
        private_class_method :retain_exhausted!

        def self.exhausted_ids(limit, projection_id: nil, asset_id: nil)
          quoted = connection.quote(Time.current)
          sql = <<~SQL.squish
            SELECT id FROM external_media_repoint_stages
            WHERE #{exhausted_sql(quoted, projection_id: projection_id, asset_id: asset_id)}
            ORDER BY available_at, id
            LIMIT #{limit.to_i}
          SQL
          connection.select_values(sql).map(&:to_i)
        end
        private_class_method :exhausted_ids

        def self.retain_ids!(ids)
          return [] if ids.empty?

          quoted = connection.quote(Time.current)
          sql = <<~SQL.squish
            UPDATE external_media_repoint_stages
            SET state = 'retained',
                failure_code = 'claim_expired',
                claim_token = NULL,
                claimed_until = NULL,
                updated_at = #{quoted}
            WHERE id IN (#{ids.map(&:to_i).join(',')})
              AND #{exhausted_sql(quoted)}
            RETURNING id
          SQL
          ApplicationRecord.transaction do
            connection.exec_query(sql).rows.map { |row| row[0].to_i }
          end
        end
        private_class_method :retain_ids!

        def self.due_sql(quoted_now, projection_id: nil, asset_id: nil)
          (["state = 'pending'", "attempt_count < #{MediaGc::MAX_ATTEMPTS.to_i}"] + scope_sql(quoted_now, projection_id: projection_id, asset_id: asset_id)).join(' AND ')
        end
        private_class_method :due_sql

        def self.exhausted_sql(quoted_now, projection_id: nil, asset_id: nil)
          (["state = 'pending'", "attempt_count >= #{MediaGc::MAX_ATTEMPTS.to_i}"] + scope_sql(quoted_now, projection_id: projection_id, asset_id: asset_id)).join(' AND ')
        end
        private_class_method :exhausted_sql

        def self.scope_sql(quoted_now, projection_id:, asset_id:)
          filters = [
            "lease_until <= #{quoted_now}",
            "available_at <= #{quoted_now}",
            "(claimed_until IS NULL OR claimed_until <= #{quoted_now})",
          ]
          filters << "external_status_projection_id = #{projection_id.to_i}" if projection_id
          filters << "external_media_asset_id = #{asset_id.to_i}" if asset_id
          filters
        end
        private_class_method :scope_sql

        def self.connection
          ExternalMediaRepointStage.connection
        end
        private_class_method :connection

        def initialize(stage_id, token = nil)
          @stage_id = stage_id
          @token = token
        end

        def release!
          ApplicationRecord.transaction { release_locked }
        rescue ActiveRecord::ActiveRecordError, Paperclip::Error => e
          postpone_id(failure_code(e))
          :failed
        end

        private

        def release_locked
          stage = ExternalMediaRepointStage.lock.find_by(id: @stage_id)
          return :missing if stage.nil?
          return :skipped if @token && stage.claim_token != @token
          return :waiting if waiting?(stage)

          attachment = MediaAttachment.lock.find_by(id: stage.media_attachment_id)
          if attachment.nil? || linked?(attachment)
            stage.destroy!
            return :released
          end
          unless same_owner?(stage, attachment)
            postpone!(stage, 'owner_mismatch')
            return :postponed
          end

          attachment.destroy!
          stage.destroy!
          :released
        end

        def waiting?(stage)
          stage.state != 'pending' || stage.lease_until > Time.current || stage.available_at > Time.current
        end

        def same_owner?(stage, attachment)
          return false unless attachment.account_id == stage.account_id
          return true if attachment.status_id == stage.status_id

          attachment.status_id.nil? && missing_status?(stage.status_id)
        end

        def missing_status?(status_id)
          !Status.unscoped.exists?(status_id)
        end

        def linked?(attachment)
          ExternalProjectionAttachment.exists?(media_attachment_id: attachment.id)
        end

        def postpone_id(code)
          stage = ExternalMediaRepointStage.find_by(id: @stage_id)
          return if stage.nil? || stage.state != 'pending'
          return if @token && stage.claim_token != @token

          postpone!(stage, code)
        end

        def postpone!(stage, code)
          now = Time.current
          attrs = { failure_code: code, claim_token: nil, claimed_until: nil, updated_at: now }
          if stage.attempt_count.to_i >= MediaGc::MAX_ATTEMPTS
            attrs[:state] = 'retained'
          else
            index = [stage.attempt_count.to_i - 1, 0].max
            attrs[:available_at] = now + MediaGc::BACKOFF.fetch(index, MediaGc::BACKOFF.last)
          end
          scope = ExternalMediaRepointStage.where(id: stage.id, state: 'pending')
          scope = scope.where(claim_token: @token) if @token
          scope.update_all(attrs)
          Rails.logger.info("[ExternalBridge::RSS] media prepare release postponed stage_id=#{stage.id} code=#{code}")
        end

        def failure_code(error)
          error.is_a?(Paperclip::Error) ? 'storage_error' : 'database_error'
        end
      end
    end
  end
end
