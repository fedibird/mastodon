# frozen_string_literal: true

namespace :user_external_credentials do
  desc 'Re-encrypt user external credentials with the primary key. DRY_RUN=1 reports without writing.'
  task rotate: :environment do
    dry_run = %w(1 true yes).include?(ENV['DRY_RUN'].to_s.downcase)
    $stdout.puts(dry_run ? 'mode=dry_run' : 'mode=write')
    report = UserCredentialVault.rotate_encryption_keys!(dry_run: dry_run)
    UserCredentialVault::Rotation.print_report(report)
  rescue UserCredentialVault::RotationError => e
    UserCredentialVault::Rotation.print_report(e.report)
    raise
  end

  desc 'Print credential counts grouped by encryption_key_id. Does not decrypt, so it does not prove ciphertext still authenticates.'
  task key_counts: :environment do
    counts = UserExternalCredential.group(:encryption_key_id).count
    if counts.empty?
      $stdout.puts 'encryption_key_id=(none) count=0'
    else
      counts.each do |key_id, count|
        $stdout.puts "encryption_key_id=#{key_id} count=#{count}"
      end
    end
  end
end
