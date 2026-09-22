# frozen_string_literal: true

class ActivityPub::ProcessStatusUpdateService < BaseService
  include JsonLdHelper
  include Redisable
  include Lockable
  include ActivityPub::ProcessStatusUpdateText
  include ActivityPub::ProcessStatusUpdateEmoji
  include ActivityPub::ProcessStatusUpdateDistribution

  RECOVERABLE_MEDIA_ERRORS = [
    Mastodon::UnexpectedResponseError,
    HTTP::TimeoutError,
    HTTP::ConnectionError,
    OpenSSL::SSL::SSLError,
    Paperclip::Error,
    Mastodon::HostValidationError,
    Mastodon::LengthValidationError,
    Mastodon::DimensionsValidationError,
    Mastodon::StreamValidationError,
  ].freeze

  # Mastodon v4.2 remote Note/Question ingestion, with Fedibird deviations:
  # text is normalized like ActivityPub::Activity::Create (the v4.2 parsers stay
  # unchanged); visibility, reply, conversation, quote, references, searchability,
  # expiry, and generator are left untouched; media uses Setting.attachments_max
  # and never truncates an existing larger set; explicit updates are rejected
  # wholesale by Setting.reject_pattern / reject_blurhash; emoji metadata is
  # merged without clearing Fedibird fields; a new explicit local mention is
  # recorded once. Mention notifications are created after commit because
  # Fedibird fan-out does not own them. A missing or null attachment does not
  # clear stored media.
  def call(status, activity_json, object_json, request_id: nil, delivery: false)
    raise ArgumentError, 'Status has unsaved changes' if status.changed?

    reset_call_state!
    @activity_json = activity_json
    @json          = object_json
    @status_parser = ActivityPub::Parser::StatusParser.new(@json)
    @uri           = @status_parser.uri
    @status        = status
    @account       = status.account
    @media_attachments_changed = false
    @poll_changed = false
    @request_id = request_id
    @delivery = delivery
    @newly_explicit_mentions = []

    return @status if !expected_type? || already_updated_more_recently?

    if @status_parser.edited_at.present? && (@status.edited_at.nil? || @status_parser.edited_at > @status.edited_at)
      handle_explicit_update!
    else
      handle_implicit_update!
    end

    @status
  end

  private

  def reset_call_state!
    @compatible_text = nil
    @quote_link_hrefs = nil
    @markdown = nil
    @rejected_blurhashes = nil
    @forwarder = nil
    @significant_changes = nil
    %i(@incoming_media @fedibird_content @reject_pattern @skip_download).each do |name|
      remove_instance_variable(name) if instance_variable_defined?(name)
    end
  end

  def handle_explicit_update!
    raise Mastodon::RejectPayload if explicit_update_rejected?

    last_edit_date = @status.edited_at.presence || @status.created_at

    with_redis_lock("create:#{@uri}") do
      Status.transaction do
        record_previous_edit!
        update_media_attachments!
        update_poll!
        update_immediate_attributes!
        update_metadata!
        create_edits!
      end

      record_new_explicit_mentions!
      notify_new_explicit_mentions!
      distribute_to_new_local_groups!
      download_media_files!
      queue_poll_notifications!

      next unless significant_changes?

      reset_preview_card!
      broadcast_updates!
    end

    return unless significant_changes? && @status_parser.edited_at > last_edit_date

    forward_activity!
    forward_local_conversation!
  end

  def handle_implicit_update!
    with_redis_lock("create:#{@uri}") do
      update_poll!(allow_significant_changes: false)
      queue_poll_notifications!
    end
  end

  def explicit_update_rejected?
    return true if reject_pattern?(compatible_text)

    incoming_media.map(&:last).each do |parser|
      return true if reject_pattern?(parser.description)
      return true if rejected_blurhash?(parser.blurhash)
    end

    false
  end

  def reject_pattern?(text)
    reject_pattern.present? && text&.match?(reject_pattern)
  end

  def reject_pattern
    return @reject_pattern if defined?(@reject_pattern)

    @reject_pattern = Setting.reject_pattern
  end

  def rejected_blurhash?(blurhash)
    blurhash.present? && rejected_blurhashes.include?(blurhash)
  end

  def rejected_blurhashes
    @rejected_blurhashes ||= Setting.reject_blurhash.to_s.split(/\r\n/).select(&:present?).uniq
  end

  def incoming_media
    return @incoming_media if defined?(@incoming_media)

    @incoming_media = if @json.key?('attachment') && !@json['attachment'].nil?
                        parsed_incoming_media
                      else
                        []
                      end
  end

  def parsed_incoming_media
    as_array(@json['attachment']).filter_map do |raw|
      next if raw.blank?

      parser = ActivityPub::Parser::MediaAttachmentParser.new(raw)
      next if parser.remote_url.blank? || unsupported_uri_scheme?(parser.remote_url)

      [raw, parser]
    end
  end

  def update_media_attachments!
    return unless @json.key?('attachment') && !@json['attachment'].nil?

    previous_media = @status.media_attachments.to_a
    previous_ids = @status.ordered_media_attachment_ids || previous_media.map(&:id)
    @next_media_attachments = []
    @downloadable_media = []
    limit = [Setting.attachments_max.to_i, previous_media.size].max

    incoming_media.each do |raw, parser|
      break if @next_media_attachments.size >= limit

      media = previous_media.find { |item| item.remote_url == parser.remote_url }
      media ||= MediaAttachment.new(account: @account, remote_url: parser.remote_url)
      apply_media_metadata!(media, parser, raw)
      media.save!
      @next_media_attachments << media
      @downloadable_media << media unless skip_media_download?(parser)
    rescue Addressable::URI::InvalidURIError => e
      Rails.logger.debug { "Invalid URL in attachment: #{e}" }
    end

    @status.ordered_media_attachment_ids = @next_media_attachments.map(&:id)
    @media_attachments_changed = true if @status.ordered_media_attachment_ids != previous_ids
  end

  def apply_media_metadata!(media, parser, raw)
    thumbnail = sanitized_remote_url(parser.thumbnail_remote_url)
    thumbhash = raw['thumbhash']
    @media_attachments_changed = true if media_metadata_changed?(media, parser, thumbnail, thumbhash)

    media.description          = parser.description
    media.focus                = parser.focus
    media.thumbnail_remote_url = thumbnail
    media.blurhash             = parser.blurhash
    media.thumbhash            = thumbhash
    media.status_id            = @status.id
  end

  def media_metadata_changed?(media, parser, thumbnail, thumbhash)
    media.remote_url != parser.remote_url ||
      media.thumbnail_remote_url != thumbnail ||
      media.description != parser.description ||
      media.blurhash != parser.blurhash ||
      media.thumbhash != thumbhash ||
      focus_changed?(media, parser)
  end

  def focus_changed?(media, parser)
    point = parser.focus
    return false if point.blank?

    x, y = (point.is_a?(Enumerable) ? point : point.to_s.split(',')).map(&:to_f)
    media.focus != "#{x},#{y}"
  end

  def sanitized_remote_url(url)
    return if url.blank? || unsupported_uri_scheme?(url)

    url
  end

  def skip_media_download?(parser)
    unsupported_media_type?(parser.file_content_type) || skip_download?
  end

  def download_media_files!
    Array(@downloadable_media).each do |media_attachment|
      media_attachment.download_file! if media_attachment.remote_url_previously_changed?
      media_attachment.download_thumbnail! if media_attachment.thumbnail_remote_url_previously_changed?
      media_attachment.save
    rescue *RECOVERABLE_MEDIA_ERRORS
      RedownloadMediaWorker.perform_in(rand(30..600).seconds, media_attachment.id)
    rescue Seahorse::Client::NetworkingError => e
      Rails.logger.warn "Error storing media attachment: #{e}"
    end

    @status.media_attachments.reload if @downloadable_media.present?
  end

  def update_poll!(allow_significant_changes: true)
    previous_poll        = @status.preloadable_poll
    @previous_expires_at = previous_poll&.expires_at
    poll_parser          = ActivityPub::Parser::PollParser.new(@json)

    if poll_parser.valid?
      apply_poll!(previous_poll, poll_parser, allow_significant_changes)
    elsif previous_poll.present?
      return unless allow_significant_changes

      previous_poll.destroy!
      @poll_changed    = true
      @status.poll_id  = nil
    end
  end

  def apply_poll!(previous_poll, poll_parser, allow_significant_changes)
    poll = previous_poll || @account.polls.new(status: @status)
    @poll_changed = true if poll_parser.significantly_changes?(poll)
    return if @poll_changed && !allow_significant_changes

    poll.last_fetched_at = Time.now.utc
    poll.options         = poll_parser.options
    poll.multiple        = poll_parser.multiple
    poll.expires_at      = poll_parser.expires_at
    poll.voters_count    = poll_parser.voters_count
    poll.cached_tallies  = poll_parser.cached_tallies
    poll.reset_votes! if @poll_changed
    poll.save!

    @status.poll_id = poll.id
  end

  def update_immediate_attributes!
    @status.text         = compatible_text
    @status.spoiler_text = @status_parser.spoiler_text || ''
    @status.sensitive    = @account.sensitized? || @status_parser.sensitive || false
    @status.language     = compatible_language

    @significant_changes = text_significantly_changed? || @status.spoiler_text_changed? || @media_attachments_changed || @poll_changed
    @status.edited_at = @status_parser.edited_at if significant_changes?
    @status.save!
  end

  def update_metadata!
    @raw_tags     = []
    @raw_mentions = []
    @raw_emojis   = []

    as_array(@json['tag']).each do |tag|
      next unless tag.is_a?(Hash)

      if equals_or_includes?(tag['type'], 'Hashtag')
        @raw_tags << tag['name']
      elsif equals_or_includes?(tag['type'], 'Mention')
        @raw_mentions << tag['href']
      elsif equals_or_includes?(tag['type'], 'Emoji')
        @raw_emojis << tag
      end
    end

    update_tags!
    update_mentions!
    update_emojis!
  end

  def update_tags!
    @status.tags = Tag.find_or_create_by_names(@raw_tags)
  end

  def update_mentions!
    previous_active = @status.active_mentions.includes(:account).to_a
    existing        = @status.mentions.includes(:account).to_a
    current         = []

    @raw_mentions.each do |href|
      mention = mention_for_href(href, existing)
      current << mention if mention
    end

    current.each(&:save!)

    removed = previous_active - current
    Mention.where(id: removed.map(&:id)).update_all(silent: true) if removed.any?
  end

  def mention_for_href(href, existing)
    return if href.blank?

    account   = ActivityPub::TagManager.instance.uri_to_resource(href, Account)
    account ||= ActivityPub::FetchRemoteAccountService.new.call(href, request_id: @request_id)
    return if account.nil?

    mention = existing.find { |item| item.account_id == account.id }
    if mention.nil?
      mention = account.mentions.new(status: @status)
      @newly_explicit_mentions << mention
    elsif mention.silent?
      mention.silent = false
      @newly_explicit_mentions << mention
    end

    mention
  end

  def record_new_explicit_mentions!
    @newly_explicit_mentions.each do |mention|
      account = mention.account
      next if account.nil? || !account.local?
      next if account.id == @status.in_reply_to_account_id

      Moderation::EventRecorder.record_interaction(
        actor: @account,
        target: account,
        event_type: :mention,
        status: @status,
        source_record: mention
      )
    end
  end

  def expected_type?
    equals_or_includes_any?(@json['type'], %w(Note Question))
  end

  def record_previous_edit!
    @previous_edit = @status.build_snapshot(at_time: @status.created_at, rate_limit: false) if @status.edits.empty?
  end

  def create_edits!
    return unless significant_changes?

    @previous_edit&.save!
    @status.snapshot!(account_id: @account.id, rate_limit: false)
  end

  def skip_download?
    return @skip_download if defined?(@skip_download)

    @skip_download ||= DomainBlock.reject_media?(@account.domain)
  end

  def unsupported_media_type?(mime_type)
    mime_type.present? && !MediaAttachment.supported_mime_types.include?(mime_type)
  end

  def significant_changes?
    @significant_changes
  end

  def text_significantly_changed?
    return false unless @status.text_changed?

    old_text, new_text = @status.text_change
    normalized_status_text(old_text) != normalized_status_text(new_text)
  end

  def normalized_status_text(text)
    return '' if text.blank?

    Sanitize.fragment(text, Sanitize::Config::MASTODON_STRICT)
  rescue ArgumentError
    ''
  end

  def already_updated_more_recently?
    @status.edited_at.present? && @status_parser.edited_at.present? && @status.edited_at > @status_parser.edited_at
  end

  def reset_preview_card!
    @status.preview_cards.clear
    LinkCrawlWorker.perform_in(rand(1..59).seconds, @status.id)
  end

  def broadcast_updates!
    ::DistributionWorker.perform_async(@status.id, 'update' => true)
  end

  def queue_poll_notifications!
    poll = @status.preloadable_poll
    return unless poll.present? && poll.expires_at.present? && poll.votes.exists?

    PollExpirationNotifyWorker.remove_from_scheduled(poll.id) if @previous_expires_at.present? && @previous_expires_at > poll.expires_at
    PollExpirationNotifyWorker.perform_at(poll.expires_at + 5.minutes, poll.id)
  end

  def forward_activity!
    forwarder.forward! if forwarder.forwardable?
  end

  def forwarder
    @forwarder ||= ActivityPub::Forwarder.new(@account, @activity_json, @status)
  end

  def forward_local_conversation!
    conversation = @status.conversation
    return if conversation.nil? || !conversation.local?
    return if @activity_json['signature'].blank?

    context_uri = value_or_id(@json['context'])
    return if context_uri.blank?
    return unless conversation_audience.include?(context_uri)

    ActivityPub::ForwardDistributionWorker.perform_async(conversation.id, Oj.dump(@activity_json))
  end

  def conversation_audience
    as_array(@json['to'] || @activity_json['to']).map { |item| value_or_id(item) }
  end
end
