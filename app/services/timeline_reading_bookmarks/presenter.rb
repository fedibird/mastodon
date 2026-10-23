# frozen_string_literal: true

module TimelineReadingBookmarks
  class Presenter
    REDIS_SOURCES = CapabilityMap::REDIS_SOURCES

    def initialize(user)
      @user = user
      @account = user.account
      @external_reasons = {}
    end

    def one(bookmark)
      many([bookmark]).first
    end

    def many(bookmarks)
      rows = bookmarks.to_a
      preload(rows)
      annotate_external!(rows)
      rows.map { |bookmark| serialize(bookmark) }
    end

    private

    def preload(rows)
      list_ids = ids_for(rows, 'list')
      group_ids = ids_for(rows, 'group')
      @list_titles = List.where(account_id: @account.id, id: list_ids).pluck(:id, :title).to_h { |id, title| [id.to_s, title] }
      @list_exists = List.where(id: list_ids).pluck(:id).map(&:to_s)
      @groups = Account.groups.where(id: group_ids).index_by { |group| group.id.to_s }
      blocked = Block.where(account_id: group_ids, target_account_id: @account.id).pluck(:account_id)
      @blocked_groups = blocked.map(&:to_s)
      @open_domains = {}
      @statuses = visible_statuses(rows)
    end

    def ids_for(rows, source)
      rows.select { |row| row.source == source }.map { |row| row.context['id'] }.compact
    end

    def visible_statuses(rows)
      ids = rows.select { |row| source_state(row) == 'available' }.map(&:anchor_status_id)
      return {} if ids.empty?

      Status.where(id: ids).includes(:account, :mentions).index_by { |status| status.id.to_s }
    end

    def serialize(bookmark)
      state = source_state(bookmark)
      {
        id: bookmark.id.to_s,
        name: bookmark.name,
        source: bookmark.source,
        source_timeline_id: bookmark.source_timeline_id,
        context: Contract.stringify(bookmark.context),
        anchor: anchor_json(bookmark),
        source_label: source_label(bookmark, state),
        availability: availability(bookmark, state),
        lock_version: bookmark.lock_version,
        created_at: bookmark.created_at.iso8601,
        updated_at: bookmark.updated_at.iso8601,
      }
    end

    def anchor_json(bookmark)
      payload = {
        version: bookmark.anchor_version,
        status_id: bookmark.anchor_status_id,
        offset_px: bookmark.offset_px,
        alignment: bookmark.alignment,
      }
      payload[:display_row_id] = bookmark.display_row_id if bookmark.display_row_id
      payload[:captured_at] = bookmark.captured_at.iso8601 if bookmark.captured_at
      payload
    end

    def availability(bookmark, state)
      entry = TimelineSeek::Capability.lookup(bookmark.source, 'status')
      limitations = []
      limitations << "retention_#{FeedManager::MAX_ITEMS}" if REDIS_SOURCES.include?(bookmark.source)
      external_reason = @external_reasons[bookmark.id]
      {
        source: state,
        anchor: anchor_state(bookmark, state),
        membership: external_reason ? 'not_in_source' : 'unchecked',
        capability: entry.level,
        reason: external_reason || entry.reason,
        limitations: limitations,
        privacy: CapabilityMap::PRIVACY[bookmark.source],
        resume: 'manual',
      }
    end

    # A positional bookmark stays on the timeline it was saved for. When that
    # view no longer delivers the anchor, say so. Do not retarget the row.
    def annotate_external!(rows)
      @external_reasons = {}
      return if @user.nil?

      ExternalBridge::Viewer.with_user(@user.id) do
        mark_withheld(rows.select { |row| row.source == 'home' && source_state(row) == 'available' }, 'home', nil)
        rows.select { |row| row.source == 'list' && source_state(row) == 'available' }.group_by { |row| row.context['id'].to_s }.each do |list_id, group|
          list = List.find_by(id: list_id, account_id: @account.id)
          next if list.nil?

          mark_withheld(group, 'list', list)
        end
      end
    end

    def mark_withheld(rows, destination, list)
      return if rows.empty?

      withheld = ExternalBridge::Feeds::Placement.new(
        user: @user,
        destination: destination,
        list: list,
        visibilities: nil,
        regenerating: false
      ).partition(rows.map(&:anchor_status_id)).withheld
      rows.each do |row|
        @external_reasons[row.id] = 'external_not_delivered' if withheld.include?(row.anchor_status_id.to_i)
      end
    end

    def source_state(bookmark)
      case bookmark.source
      when 'home', 'limited', 'personal', 'hashtag', 'public'
        'available'
      when 'list'
        list_state(bookmark.context['id'].to_s)
      when 'group'
        group_state(bookmark.context['id'].to_s)
      when 'domain'
        domain_state(bookmark.context['domain'].to_s)
      else
        'not_accessible'
      end
    end

    def list_state(id)
      return 'available' if @list_titles.key?(id)
      return 'not_accessible' if @list_exists.include?(id)

      'missing'
    end

    def group_state(id)
      group = @groups[id]
      return 'missing' if group.nil?
      return 'not_accessible' if group.domain.present? || group.suspended? || @blocked_groups.include?(id)

      'available'
    end

    def domain_state(domain)
      return 'uncertain' if domain.blank?

      open = @open_domains.fetch(domain) do
        @open_domains[domain] = domain_open?(domain)
      end
      open ? 'available' : 'uncertain'
    end

    def domain_open?(domain)
      normalized = TagManager.instance.normalize_domain(domain)
      return false if normalized.blank?

      Account.where(domain: normalized).without_suspended.without_silenced.exists?
    rescue Addressable::URI::InvalidURIError, IDN::Idna::IdnaError
      false
    end

    def anchor_state(bookmark, state)
      return 'unchecked' unless state == 'available'

      status = @statuses[bookmark.anchor_status_id]
      return 'not_found' if status.nil? || !StatusPolicy.new(@account, status).show?

      'visible'
    end

    def source_label(bookmark, state)
      return nil unless state == 'available'

      case bookmark.source
      when 'list' then @list_titles[bookmark.context['id'].to_s]
      when 'group' then @groups[bookmark.context['id'].to_s]&.username
      when 'hashtag' then bookmark.context['hashtag']
      when 'domain' then bookmark.context['domain']
      end
    end
  end
end
