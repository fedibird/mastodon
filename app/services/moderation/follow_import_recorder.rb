# frozen_string_literal: true

# Records a follow-import batch and its target set into the moderation ledger.
#
# Follow import is a high-value observation point: the whole target set is
# presented to the server before any follow is executed, so it is recorded up
# front. Resolvable addresses are linked to a ModerationSubject; unresolved ones
# keep a pseudonymous target_key_hash so they can still be correlated later.
#
# Recording only — no scoring or enforcement. The class-level entry point is
# failure-tolerant so a recording error never breaks the import.
module Moderation
  class FollowImportRecorder
    class << self
      def record_batch(**options)
        new.record_batch(**options)
      rescue StandardError => e
        Rails.logger.warn("[Moderation::FollowImportRecorder] failed to record follow import batch: #{e.class}: #{e.message}")
        nil
      end
    end

    def record_batch(account:, accts:, import: nil, mode: nil, imported_at: nil)
      imported_at ||= Time.now.utc
      subject = ModerationSubject.for_account!(account, observed_at: imported_at)

      resolved_count   = 0
      unresolved_count = 0
      target_rows      = []

      accts.each_with_index do |raw_acct, index|
        acct = raw_acct.to_s.strip
        next if acct.blank?

        target_account = resolve_account(acct)

        if target_account
          resolved_count += 1
          target_subject = ModerationSubject.for_account!(target_account, observed_at: imported_at)
          target_rows << {
            target_subject_id: target_subject.id,
            position: index,
            prior_relationship_state: { following: account.following?(target_account) },
          }
        else
          unresolved_count += 1
          target_rows << {
            target_key_hash: hash_acct(acct),
            position: index,
          }
        end
      end

      batch = nil

      ApplicationRecord.transaction do
        batch = FollowImportBatch.create!(
          subject: subject,
          import_id: import&.id,
          imported_at: imported_at,
          mode: normalize_mode(mode),
          target_count: target_rows.size,
          resolved_target_count: resolved_count,
          unresolved_target_count: unresolved_count,
          account_age_seconds: account_age_seconds(account, imported_at),
          migration_evidence: migration_evidence(account)
        )

        target_rows.each { |attrs| batch.targets.create!(attrs) }
      end

      batch
    end

    private

    # Resolve an account address to a known account without hitting the network.
    def resolve_account(acct)
      username, domain = acct.split('@', 2)
      return if username.blank?

      domain = nil if domain.blank? || TagManager.instance.local_domain?(domain)

      if domain.nil?
        Account.find_local(username)
      else
        Account.find_remote(username, domain)
      end
    rescue StandardError
      nil
    end

    def hash_acct(acct)
      username, domain = acct.split('@', 2)
      domain = Rails.configuration.x.local_domain if domain.blank?
      Digest::SHA256.hexdigest("#{username.to_s.downcase}@#{domain.to_s.downcase}")
    end

    def normalize_mode(mode)
      case mode&.to_sym
      when :merge then :merge
      when :overwrite then :overwrite
      else :unknown
      end
    end

    def account_age_seconds(account, at)
      return if account.created_at.nil?

      (at - account.created_at).to_i
    end

    def migration_evidence(account)
      account.aliases.exists? ? :weak : :none
    rescue StandardError
      :none
    end
  end
end
