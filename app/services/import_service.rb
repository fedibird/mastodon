# frozen_string_literal: true

require 'csv'

class ImportService < BaseService
  ROWS_PROCESSING_LIMIT = 20_000

  def call(import)
    @import  = import
    @account = @import.account

    case @import.type
    when 'following'
      import_follows!
    when 'account_subscribings'
      import_account_subscribings!
    when 'blocking'
      import_blocks!
    when 'muting'
      import_mutes!
    when 'domain_blocking'
      import_domain_blocks!
    when 'bookmarks'
      import_bookmarks!
    end
  end

  private

  def import_follows!
    parse_import_data!(['Account address'])
    record_follow_import_batch!
    import_relationships!('follow', 'unfollow', @account.following.map { |account| { acct: account.acct }}, ROWS_PROCESSING_LIMIT, show_reblogs: { header: 'Show boosts', default: true }, notify: { header: 'Notify on new posts', default: false }, languages: { header: 'Languages', default: nil }, delivery: { header: 'Delivery to home', default: true })
  end

  # Record the follow-import target set into the moderation ledger before the
  # follows are executed (the whole set is known here after CSV parsing).
  def record_follow_import_batch!
    accts = @data.take(ROWS_PROCESSING_LIMIT).filter_map { |row| row['Account address']&.strip.presence }

    Moderation::FollowImportRecorder.record_batch(account: @account, accts: accts, import: @import, mode: @import.mode)
  end

  def import_account_subscribings!
    parse_import_data!(['Account address'])
    import_relationships!('account_subscribe', 'account_unsubscribe', @account.active_subscribes.map { |subscribe| { acct: subscribe.target_account.acct, list_id: subscribe.list_id }}, ROWS_PROCESSING_LIMIT, lists: { header: 'List', default: nil }, show_reblogs: { header: 'Show boosts', default: true }, media_only: { header: 'Media only', default: false })
  end

  def import_blocks!
    parse_import_data!(['Account address'])
    import_relationships!('block', 'unblock', @account.blocking.map { |account| { acct: account.acct }}, ROWS_PROCESSING_LIMIT)
  end

  def import_mutes!
    parse_import_data!(['Account address'])
    import_relationships!('mute', 'unmute', @account.muting.map { |account| { acct: account.acct }}, ROWS_PROCESSING_LIMIT, notifications: { header: 'Hide notifications', default: true })
  end

  def import_domain_blocks!
    parse_import_data!(['#domain'])
    items = @data.take(ROWS_PROCESSING_LIMIT).map { |row| row['#domain'].strip }

    if @import.overwrite?
      presence_hash = items.index_with(true)

      @account.domain_blocks.find_each do |domain_block|
        if presence_hash[domain_block.domain]
          items.delete(domain_block.domain)
        else
          @account.unblock_domain!(domain_block.domain)
        end
      end
    end

    items.each do |domain|
      @account.block_domain!(domain)
    end

    AfterAccountDomainBlockWorker.push_bulk(items) do |domain|
      [@account.id, domain]
    end
  end

  def import_relationships!(action, undo_action, overwrite_scope, limit, extra_fields = {})
    local_domain_suffix = "@#{Rails.configuration.x.local_domain}"
    items = @data.take(limit).each_with_object({}) do |row, mapping|
      key = row['Account address']&.strip&.delete_suffix(local_domain_suffix)
      return if key.blank?

      extra = extra_fields.each_with_object({}) {|(key, field_settings), extra| extra[key] = row[field_settings[:header]]&.strip || field_settings[:default] }

      if extra[:lists].nil?
        extra.delete(:lists)
      else
        extra[:list_id] = List.find_or_create_by!({ account_id: @account.id, title: extra.delete(:lists) }).id
        key = "#{key} #{extra[:list_id]}"
      end

      mapping[key] = extra
    end

    if @import.overwrite?
      overwrite_scope.each do |scope|
        acct   = scope[:acct]
        key    = scope[:list_id] ? "#{acct} #{scope[:list_id]}" : acct
        option = scope[:list_id] ? { list_id: scope[:list_id] } : {}

        if items[key]
          Import::RelationshipWorker.perform_async(@account.id, acct, action, items.delete(key).stringify_keys)
        else
          Import::RelationshipWorker.perform_async(@account.id, acct, undo_action, option)
        end
      end
    end

    items = items.map { |item| [item[0].split(' ')[0], item[1]] }

    # Process one item representing the domain ahead of time.
    preceding_items = items.uniq { |acct, _| acct.split('@')[1] }
    sorted_items    = preceding_items + (items - preceding_items)

    Import::RelationshipWorker.push_bulk(sorted_items) do |acct, extra|
      [@account.id, acct, action, extra.stringify_keys]
    end
  end

  def import_bookmarks!
    parse_import_data!(['#uri'])
    items = @data.take(ROWS_PROCESSING_LIMIT).map { |row| row['#uri'].strip }

    if @import.overwrite?
      presence_hash = items.index_with(true)

      @account.bookmarks.find_each do |bookmark|
        if presence_hash[bookmark.status.uri]
          items.delete(bookmark.status.uri)
        else
          bookmark.destroy!
        end
      end
    end

    statuses = items.filter_map do |uri|
      status = ActivityPub::TagManager.instance.uri_to_resource(uri, Status)
      next if status.nil? && ActivityPub::TagManager.instance.local_uri?(uri)

      status || ActivityPub::FetchRemoteStatusService.new.call(uri)
    end

    account_ids         = statuses.map(&:account_id)
    preloaded_relations = relations_map_for_account(@account&.id, account_ids)

    statuses.keep_if { |status| StatusPolicy.new(@account, status, preloaded_relations).show? }

    statuses.each do |status|
      @account.bookmarks.find_or_create_by!(account: @account, status: status)
    end
  end

  def parse_import_data!(default_headers)
    data = CSV.parse(import_data, headers: true)
    data = CSV.parse(import_data, headers: default_headers) unless data.headers&.first&.strip&.include?(' ')
    @data = data.reject(&:blank?)
  end

  def import_data
    Paperclip.io_adapters.for(@import.data).read
  end

  def relations_map_for_account(account_id, account_ids)
    presenter = AccountRelationshipsPresenter.new(account_ids, account_id)
    {
      blocking: {},
      blocked_by: presenter.blocked_by,
      muting: {},
      following: presenter.following,
      domain_blocking_by_domain: {},
    }
  end
end
