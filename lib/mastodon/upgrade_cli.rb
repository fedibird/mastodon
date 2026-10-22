# frozen_string_literal: true

require_relative '../../config/boot'
require_relative '../../config/environment'
require_relative 'cli_helper'

module Mastodon
  class UpgradeCLI < Thor
    include CLIHelper

    def self.exit_on_failure?
      true
    end

    CURRENT_STORAGE_SCHEMA_VERSION = 1

    option :dry_run, type: :boolean, default: false
    option :verbose, type: :boolean, default: false, aliases: [:v]
    desc 'storage-schema', 'Upgrade storage schema of various file attachments to the latest version'
    long_desc <<~LONG_DESC
      Iterates over every file attachment of every record and, if its storage schema is outdated, performs the
      necessary upgrade to the latest one. In practice this means e.g. moving files to different directories.

      Will most likely take a long time.
    LONG_DESC
    def storage_schema
      progress = create_progress_bar(nil)
      dry_run  = dry_run? ? ' (DRY RUN)' : ''
      records  = 0

      klasses = [
        Account,
        CustomEmoji,
        MediaAttachment,
        PreviewCard,
      ]

      klasses.each do |klass|
        attachment_names = klass.attachment_definitions.keys

        klass.find_each do |record|
          attachment_names.each do |attachment_name|
            attachment = record.public_send(attachment_name)
            upgraded   = false

            next if attachment.blank? || attachment.storage_schema_version >= CURRENT_STORAGE_SCHEMA_VERSION

            styles = attachment.styles.keys

            styles << :original unless styles.include?(:original)

            styles.each do |style|
              success = begin
                case Paperclip::Attachment.default_options[:storage]
                when :s3
                  upgrade_storage_s3(progress, attachment, style)
                when :fog
                  upgrade_storage_fog(progress, attachment, style)
                when :filesystem
                  upgrade_storage_filesystem(progress, attachment, style)
                end
              end

              upgraded = true if style == :original && success

              progress.increment
            end

            attachment.instance_write(:storage_schema_version, CURRENT_STORAGE_SCHEMA_VERSION) if upgraded
          end

          if record.changed?
            record.save unless dry_run?
            records += 1
          end
        end
      end

      progress.total = progress.progress
      progress.finish

      say("Upgraded storage schema of #{records} records#{dry_run}", :green, true)
    end

    option :apply, type: :boolean, default: false
    option :verify, type: :boolean, default: false
    option :confirm_readers_ready, type: :boolean, default: false
    option :user_id, type: :string
    option :subscription_id, type: :string
    option :batch_size, type: :string, default: '100'
    option :limit, type: :string, default: '1000'
    option :pause, type: :string, default: '0'
    option :checkpoint, type: :string
    option :lock_timeout, type: :string, default: '2s'
    option :statement_timeout, type: :string, default: '30s'
    desc 'external-status-visibility', 'Migrate external projection statuses from personal visibility to external'
    long_desc <<~LONG_DESC
      Forward-only operator migration for external projections. Rows stay at the
      same status id. Ordinary personal posts are not candidates.

      The default is a dry-run and writes nothing. --apply requires --checkpoint,
      --confirm-readers-ready, and Setting.external_bridge_external_visibility
      to be on. --confirm-readers-ready is the operator's statement that readers
      understand visibility 201. This command cannot see other processes.

      Resume with the same checkpoint file. A file from another database, instance,
      scope, or direction is refused. --verify is read-only and is the only way
      to claim a scope or the instance is complete.

      This does not turn the switch on, does not reverse external rows, and does
      not deliver them to home, lists, or streaming.
    LONG_DESC
    def external_status_visibility
      requested = { requested: false }
      previous_int = trap('INT') { requested[:requested] = true }
      previous_term = trap('TERM') { requested[:requested] = true }
      result = ExternalBridge::VisibilityMigration::Runner.call(visibility_migration_options(requested))
      say(result.to_s)
      exit(result.exit_code) unless result.exit_code.zero?
    rescue ExternalBridge::VisibilityMigration::Refusal => e
      say(e.message, :red)
      exit(1)
    rescue ExternalBridge::VisibilityMigration::Runner::CacheIncomplete => e
      say("#{e.message} Resume the same checkpoint.", :red)
      exit(6)
    ensure
      trap('INT', previous_int || 'DEFAULT')
      trap('TERM', previous_term || 'DEFAULT')
    end

    private

    def visibility_migration_options(requested)
      {
        apply: options[:apply],
        verify: options[:verify],
        confirm_readers_ready: options[:confirm_readers_ready],
        user_id: options[:user_id],
        subscription_id: options[:subscription_id],
        batch_size: options[:batch_size],
        limit: options[:limit],
        pause: options[:pause],
        checkpoint: options[:checkpoint],
        lock_timeout: options[:lock_timeout],
        statement_timeout: options[:statement_timeout],
        stop_check: -> { requested[:requested] },
      }
    end

    def upgrade_storage_s3(progress, attachment, style)
      previous_storage_schema_version = attachment.storage_schema_version
      object                          = attachment.s3_object(style)
      success                         = true

      attachment.instance_write(:storage_schema_version, CURRENT_STORAGE_SCHEMA_VERSION)

      new_object = attachment.s3_object(style)

      if new_object.key != object.key && object.exists?
        progress.log("Moving #{object.key} to #{new_object.key}") if options[:verbose]

        begin
          object.move_to(new_object, acl: attachment.s3_permissions(style)) unless dry_run?
        rescue => e
          progress.log(pastel.red("Error processing #{object.key}: #{e}"))
          success = false
        end
      end

      # Because we move files style-by-style, it's important to restore
      # previous version at the end. The upgrade will be recorded after
      # all styles are updated
      attachment.instance_write(:storage_schema_version, previous_storage_schema_version)
      success
    end

    def upgrade_storage_fog(_progress, _attachment, _style)
      say('The fog storage driver is not supported for this operation at this time', :red)
      exit(1)
    end

    def upgrade_storage_filesystem(progress, attachment, style)
      previous_storage_schema_version = attachment.storage_schema_version
      previous_path                   = attachment.path(style)
      success                         = true

      attachment.instance_write(:storage_schema_version, CURRENT_STORAGE_SCHEMA_VERSION)

      upgraded_path = attachment.path(style)

      if upgraded_path != previous_path && File.exist?(previous_path)
        progress.log("Moving #{previous_path} to #{upgraded_path}") if options[:verbose]

        begin
          unless dry_run?
            FileUtils.mkdir_p(File.dirname(upgraded_path))
            FileUtils.mv(previous_path, upgraded_path)

            begin
              FileUtils.rmdir(File.dirname(previous_path), parents: true)
            rescue Errno::ENOTEMPTY
              # OK
            end
          end
        rescue => e
          progress.log(pastel.red("Error processing #{previous_path}: #{e}"))
          success = false

          unless dry_run?
            begin
              FileUtils.rmdir(File.dirname(upgraded_path), parents: true)
            rescue Errno::ENOTEMPTY
              # OK
            end
          end
        end
      end

      # Because we move files style-by-style, it's important to restore
      # previous version at the end. The upgrade will be recorded after
      # all styles are updated
      attachment.instance_write(:storage_schema_version, previous_storage_schema_version)
      success
    end
  end
end
