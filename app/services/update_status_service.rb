# frozen_string_literal: true

class UpdateStatusService < BaseService
  include Redisable
  include LanguagesHelper

  class NoChangesSubmittedError < StandardError; end

  # Edit a local status in place.
  #
  # Quote, references, visibility, circle, searchability, expiry, and the
  # generating application are not accepted here. Omitted media and poll
  # parameters keep the current attachments so a text-only edit does not
  # clear them. A present but blank poll removes the poll.
  # @param [Status] status
  # @param [Integer] account_id
  # @param [Hash] options
  def call(status, account_id, options = {})
    @status                    = status
    @options                   = options
    @account_id                = account_id
    @media_attachments_changed = false
    @poll_changed              = false
    @poll_votes_invalidated    = false
    @introduced_mentions       = []
    @text_changed              = false
    original_text              = @status.text.to_s

    Status.transaction do
      create_previous_edit!
      update_media_attachments! if @options.key?(:media_ids) || @options.key?(:media_attributes)
      update_poll! if @options.key?(:poll)
      update_immediate_attributes!
      update_metadata!
      create_edit!
      @text_changed = @status.text.to_s != original_text
    end

    ProcessMentionsService.new.deliver_mention_notifications(@introduced_mentions)
    queue_poll_notifications!
    reset_preview_card!
    broadcast_updates!

    @status
  rescue NoChangesSubmittedError
    @status.reload
  end

  private

  def update_media_attachments!
    previous_media_attachments = @status.ordered_media_attachments.to_a
    next_media_attachments     = @options.key?(:media_ids) ? validate_media! : previous_media_attachments

    Array(@options[:media_attributes]).each do |attributes|
      attrs = media_attribute_hash(attributes)
      media = next_media_attachments.find { |attachment| attachment.id == attrs[:id].to_i }
      next if media.nil?

      media.update!(attrs.slice(:thumbnail, :description, :focus))
      @media_attachments_changed ||= media.significantly_changed?
    end

    return unless @options.key?(:media_ids)

    added_media_attachments = next_media_attachments - previous_media_attachments
    MediaAttachment.where(id: added_media_attachments.map(&:id)).update_all(status_id: @status.id)

    @status.ordered_media_attachment_ids = Array(@options[:media_ids]).map(&:to_i) & next_media_attachments.map(&:id)
    @media_attachments_changed ||= previous_media_attachments.map(&:id) != @status.ordered_media_attachment_ids
    @status.media_attachments.reload
  end

  def media_attribute_hash(attributes)
    if attributes.respond_to?(:to_unsafe_h)
      attributes.to_unsafe_h.symbolize_keys
    else
      attributes.symbolize_keys
    end
  end

  def validate_media!
    return [] if @options[:media_ids].blank? || !@options[:media_ids].is_a?(Enumerable)

    max = Setting.attachments_max.to_i
    raise Mastodon::ValidationError, I18n.t('media_attachments.validations.too_many') if @options[:media_ids].size > max || poll_with_media_forbidden?

    media_attachments = @status.account.media_attachments.where(status_id: [nil, @status.id]).where(scheduled_status_id: nil).where(id: @options[:media_ids].take(max).map(&:to_i)).to_a

    raise Mastodon::ValidationError, I18n.t('media_attachments.validations.images_and_video') if media_attachments.size > 1 && media_attachments.find(&:audio_or_video?)
    raise Mastodon::ValidationError, I18n.t('media_attachments.validations.not_ready') if media_attachments.any?(&:not_processed?)

    media_attachments
  end

  def poll_with_media_forbidden?
    !Setting.allow_poll_image && poll_remaining?
  end

  def poll_remaining?
    if @options.key?(:poll)
      @options[:poll].present?
    else
      @status.preloadable_poll.present?
    end
  end

  def update_poll!
    previous_poll        = @status.preloadable_poll
    @previous_expires_at = previous_poll&.expires_at
    poll_attributes      = poll_attribute_hash

    if poll_attributes.present?
      poll = previous_poll || @status.account.polls.new(status: @status, votes_count: 0)
      next_options  = poll_attributes.key?(:options) ? Array(poll_attributes[:options]) : poll.options
      next_multiple = poll_attributes.key?(:multiple) ? ActiveModel::Type::Boolean.new.cast(poll_attributes[:multiple]) : poll.multiple

      @poll_votes_invalidated = next_options != poll.options || next_multiple != poll.multiple
      @poll_changed = true if @poll_votes_invalidated

      if poll_attributes.key?(:hide_totals)
        next_hide_totals = ActiveModel::Type::Boolean.new.cast(poll_attributes[:hide_totals]) || false
        @poll_changed = true if next_hide_totals != poll.hide_totals
        poll.hide_totals = next_hide_totals
      end

      poll.options     = next_options
      poll.multiple    = next_multiple
      poll.expires_in  = poll_attributes[:expires_in] if poll_attributes.key?(:expires_in)
      poll.reset_votes! if @poll_votes_invalidated
      poll.save!

      @status.poll_id = poll.id
      @status.association(:preloadable_poll).reset
    elsif previous_poll.present?
      previous_poll.destroy
      @poll_changed = true
      @status.poll_id = nil
      @status.association(:preloadable_poll).reset
    end

    @poll_changed = true if @previous_expires_at != @status.preloadable_poll&.expires_at
  end

  def poll_attribute_hash
    poll = @options[:poll]
    return if poll.blank?

    poll.respond_to?(:to_unsafe_h) ? poll.to_unsafe_h.symbolize_keys : poll.symbolize_keys
  end

  def update_immediate_attributes!
    if @options.key?(:text)
      if @options[:text].blank? && @options[:spoiler_text].present?
        @status.text = @options[:spoiler_text]
        @options.delete(:spoiler_text)
      else
        @status.text = @options[:text] || ''
      end
    end

    @status.spoiler_text = @options[:spoiler_text] || '' if @options.key?(:spoiler_text)
    assign_sensitive!
    @status.language = valid_locale_cascade(@options[:language], @status.language, @status.account.user&.preferred_posting_language, I18n.default_locale) if @options.key?(:language)

    validate_prohibited_words!

    # Raising here rolls the original snapshot and any media or poll writes back.
    raise NoChangesSubmittedError unless significant_changes?

    @status.edited_at = Time.now.utc
    @status.save!
  end

  def assign_sensitive!
    return unless @options.key?(:sensitive) || @options.key?(:spoiler_text)

    sensitive = if @options.key?(:sensitive)
                  ActiveModel::Type::Boolean.new.cast(@options[:sensitive])
                else
                  @status.sensitive
                end

    @status.sensitive = sensitive || @options[:spoiler_text].present?
  end

  def validate_prohibited_words!
    words = (@status.account.user&.setting_prohibited_words || '').split(',').map(&:strip).select(&:present?)
    return if words.empty?

    text = [@status.spoiler_text, @status.text].join(' ')
    raise Mastodon::ValidationError, I18n.t('status_prohibit.validations.prohibited_words') if words.any? { |word| text.include?(word) }
  end

  def reset_preview_card!
    return unless @text_changed

    @status.preview_cards.clear
    LinkCrawlWorker.perform_async(@status.id)
  end

  def update_metadata!
    @introduced_mentions = if @status.personal_visibility?
                             []
                           else
                             ProcessMentionsService.new.call(@status, nil, edit: true)
                           end
    ProcessHashtagsService.new.call(@status, [], replace: true)
  end

  def broadcast_updates!
    if @status.account.high_priority?
      PriorityDistributionWorker.perform_async(@status.id, { 'update' => true })
    else
      DistributionWorker.perform_async(@status.id, { 'update' => true })
    end

    return if @status.personal_visibility?

    excluded = introduced_remote_mention_inboxes
    if excluded.empty?
      ActivityPub::StatusUpdateDistributionWorker.perform_async(@status.id)
    else
      ActivityPub::StatusUpdateDistributionWorker.perform_async(@status.id, 'exclude_inboxes' => excluded)
    end
  end

  # Create already targets these inboxes. Keep them out of this edit's
  # Update so a newly mentioned remote account is not offered both.
  def introduced_remote_mention_inboxes
    @introduced_mentions.each_with_object([]) do |mention, urls|
      account = mention.account
      next unless account&.activitypub?

      urls << account.inbox_url if account.inbox_url.present?
      urls << account.shared_inbox_url if account.shared_inbox_url.present?
    end.uniq
  end

  def queue_poll_notifications!
    return unless @options.key?(:poll)

    poll = @status.preloadable_poll

    return unless poll.present? && poll.expires_at.present? && @previous_expires_at != poll.expires_at

    PollExpirationNotifyWorker.remove_from_scheduled(poll.id) if @previous_expires_at.present?
    PollExpirationNotifyWorker.perform_at(poll.expires_at, poll.id)
  end

  def create_previous_edit!
    return if @status.edits.any?

    @status.snapshot!(at_time: @status.created_at, rate_limit: false)
  end

  def create_edit!
    @status.snapshot!(account_id: @account_id)
  end

  def significant_changes?
    @status.changed? || @poll_changed || @media_attachments_changed
  end
end
