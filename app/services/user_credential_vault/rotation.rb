# frozen_string_literal: true

module UserCredentialVault
  # Re-encrypts rows onto the current primary key.
  #
  # Each row is decrypted with the key id stored on that row, and the purpose
  # is rebuilt from that row's payload schema, binding_id, user_id, provider,
  # purpose, and credential_type. The replacement ciphertext is written with
  # the primary key in one conditional UPDATE that also sets encryption_key_id.
  # binding_id is not changed. last_used_at is not changed. Plaintext is not
  # printed and is not assigned to a model attribute.
  #
  # An unreadable row is reported and left in place. Rotation never deletes it.
  class Rotation
    BATCH_SIZE = 100

    Report = Struct.new(:examined, :already_primary, :rotated, :would_rotate, :failures, :dry_run, keyword_init: true)

    class << self
      def call(dry_run:)
        keyring = Keyring.load!
        examined = 0
        already_primary = 0
        rotated = 0
        would_rotate = 0
        failures = []

        UserExternalCredential.find_each(batch_size: BATCH_SIZE) do |credential|
          examined += 1
          case rewrite!(credential, keyring: keyring, dry_run: dry_run)
          when :already_primary
            already_primary += 1
          when :would_rotate
            would_rotate += 1
          when :rotated
            rotated += 1
            would_rotate += 1
          end
        rescue UserCredentialVault::Error, ActiveRecord::RecordNotFound => e
          failures << {
            id: credential.id,
            encryption_key_id: credential.encryption_key_id,
            error_class: e.class.name,
          }
        end

        Report.new(
          examined: examined,
          already_primary: already_primary,
          rotated: rotated,
          would_rotate: would_rotate,
          failures: failures,
          dry_run: dry_run
        )
      end

      def print_report(report, stdout = $stdout)
        stdout.puts(
          "examined=#{report.examined} already_primary=#{report.already_primary} " \
          "rotated=#{report.rotated} would_rotate=#{report.would_rotate} " \
          "failed=#{report.failures.size} dry_run=#{report.dry_run}"
        )
        report.failures.each do |failure|
          stdout.puts("failure id=#{failure.fetch(:id)} encryption_key_id=#{failure.fetch(:encryption_key_id)} error=#{failure.fetch(:error_class)}")
        end
      end

      private

      def rewrite!(credential, keyring:, dry_run:)
        payload = nil
        result = nil

        begin
          UserExternalCredential.transaction do
            locked = UserExternalCredential.lock.find(credential.id)
            if locked.encryption_key_id == keyring.primary_id
              result = :already_primary
            else
              payload = decrypt(locked, keyring)
              result = write_primary!(locked, payload, keyring, dry_run)
            end
          end
          result
        ensure
          payload = nil
        end
      end

      def decrypt(locked, keyring)
        raw = Cipher.decrypt(
          locked.encrypted_payload,
          key: keyring.key_for!(locked.encryption_key_id),
          purpose: purpose_for(locked)
        )
        Payload.unwrap(raw)
      end

      def write_primary!(locked, payload, keyring, dry_run)
        return :would_rotate if dry_run

        ciphertext = Cipher.encrypt(payload, key: keyring.primary_key, purpose: purpose_for(locked))
        updated = UserExternalCredential.where(id: locked.id, encryption_key_id: locked.encryption_key_id).update_all(
          encrypted_payload: ciphertext,
          encryption_key_id: keyring.primary_id,
          updated_at: Time.current
        )
        raise IntegrityError, 'credential row changed during rotation' unless updated == 1

        :rotated
      end

      def purpose_for(locked)
        Context.build(
          payload_schema: Payload::VERSION,
          binding_id: locked.binding_id,
          user_id: locked.user_id,
          provider: locked.provider,
          purpose: locked.purpose,
          credential_type: locked.credential_type
        )
      end
    end
  end
end
