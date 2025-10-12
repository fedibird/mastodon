# frozen_string_literal: true

class PostStatusService < BaseService
  include Redisable

  MIN_SCHEDULE_OFFSET = 5.minutes.freeze
  MIN_EXPIRE_OFFSET   = 40.seconds.freeze # The original intention is 60 seconds, but we have a margin of 20 seconds.

  # Post a text status update, fetch and notify remote users mentioned
  # @param [Account] account Account from which to post
  # @param [Hash] options
  # @option [String] :text Message
  # @option [Status] :thread Optional status to reply to
  # @option [Boolean] :sensitive
  # @option [String] :visibility
  # @option [String] :spoiler_text
  # @option [String] :language
  # @option [String] :scheduled_at
  # @option [String] :expires_at
  # @option [String] :expires_action
  # @option [Circle] :circle Optional circle to target the status to
  # @option [Hash] :poll Optional poll to attach
  # @option [Enumerable] :media_ids Optional array of media IDs to attach
  # @option [Doorkeeper::Application] :application
  # @option [String] :idempotency Optional idempotency key
  # @option [Boolean] :with_rate_limit
  # @option [String] :searchability
  # @option [Boolean] :notify Optional notification of completion of schedule post
  # @return [Status]
  def call(account, options = {})
    @account     = account
    @options     = options
    @text        = @options[:text] || ''
    @in_reply_to = @options[:thread]
    @quote_id    = @options[:quote_id]
    @circle      = @options[:circle]

    return idempotency_duplicate if idempotency_given? && idempotency_duplicate?
    return suspended_account     if @account.suspended?

    validate_media!
    validate_expires!
    validate_prohibited_words!
    preprocess_attributes!
    validate_prohibited_visibilities!
    preprocess_quote!

    if scheduled?
      schedule_status!
    else
      process_status!
      postprocess_status!
      bump_potential_friendship!
    end

    redis.setex(idempotency_key, 3_600, @status.id) if idempotency_given?

    create_notification!

    @status
  end

  private

  def create_notification!
    NotifyService.new.call(@status.account, :scheduled_status, @status) if @options[:notify] && @status.account.local?
  end

  def status_from_uri(uri)
    ActivityPub::TagManager.instance.uri_to_resource(uri, Status)
  end

  def quote_from_url(url)
    return nil if url.nil?

    quote = ResolveURLService.new.call(url)
    status_from_uri(quote.uri) if quote
  rescue
    nil
  end

  def preprocess_attributes!
    @sensitive      = (@options[:sensitive].nil? ? @account.user&.setting_default_sensitive : @options[:sensitive]) || @options[:spoiler_text].present?
    @text           = @options.delete(:spoiler_text) if @text.blank? && @options[:spoiler_text].present?

    @visibility       = (@options[:visibility] || @account.user&.setting_default_privacy)&.to_sym
    if @visibility != :personal
      @visibility     = :unlisted if @visibility == :public                    && @account.silenced?
      @visibility     = :private  if %i(public unlisted).include?(@visibility) && @account.hard_silenced?
      @visibility     = :limited  if @circle.present? || @visibility != :direct && @in_reply_to&.limited_visibility?
    end

    @searchability  = searchability
    @scheduled_at   = @options[:scheduled_at].is_a?(Time) ? @options[:scheduled_at] : @options[:scheduled_at]&.to_datetime&.to_time
    if @quote_id.nil? && md = @text.match(/QT:\s*\[\s*(https:\/\/.+?)\s*\]/)
      @quote_id = quote_from_url(md[1])&.id
      @text.sub!(/QT:\s*\[.*?\]/, '')
    end
  rescue ArgumentError
    raise ActiveRecord::RecordInvalid
  end

  def searchability
    case @options[:searchability]&.to_sym
    when :public
      case @visibility&.to_sym when :public then :public when :unlisted, :private then :private else :direct end
    when :unlisted, :private
      case @visibility&.to_sym when :public, :unlisted, :private then :private else :direct end
    when nil
      @account.searchability
    else
      :direct
    end
  end

  def preprocess_quote!
    if @quote_id.present?
      quote = Status.find(@quote_id)
      @quote_id = quote.reblog_of_id.to_s if quote.reblog?
    end
  end

  def process_status!
    # The following transaction block is needed to wrap the UPDATEs to
    # the media attachments when the status is created

    ApplicationRecord.transaction do
      @status = @account.statuses.create!(status_attributes)
      @status.capability_tokens.create! if @status.limited_visibility?
    end

    ProcessHashtagsService.new.call(@status)
    ProcessStatusReferenceService.new.call(@status, status_reference_ids: (@options[:status_reference_ids] || []) + [@quote_id], urls: @options[:status_reference_urls])
    ProcessMentionsService.new.call(@status, @circle) unless @status.personal_visibility?
  end

  def schedule_status!
    status_for_validation = @account.statuses.build(status_attributes)

    if status_for_validation.valid?
      status_for_validation.destroy

      # The following transaction block is needed to wrap the UPDATEs to
      # the media attachments when the scheduled status is created

      ApplicationRecord.transaction do
        @status = @account.scheduled_statuses.create!(scheduled_status_attributes)
      end
    else
      raise ActiveRecord::RecordInvalid
    end
  end

  def postprocess_status!
    begin
      redis.sadd("statuses/#{@status.id}/processing", 'LinkCrawlWorker')
      redis.expire("statuses/#{@status.id}/processing", 60.seconds)
      LinkCrawlWorker.new.perform(@status.id)
    rescue
      # ignore
    end

    @account.high_priority? ?
      PriorityDistributionWorker.perform_async(@status.id) :
      DistributionWorker.perform_async(@status.id)
    ActivityPub::DistributionWorker.perform_async(@status.id) unless @status.personal_visibility?
    PollExpirationNotifyWorker.perform_at(@status.poll.expires_at, @status.poll.id) if @status.poll
    @status.status_expire.queue_action if expires_soon?
  end

  def expires_soon?
    expires_at = @status&.status_expire&.expires_at
    expires_at.present? && expires_at <= Time.now.utc + MIN_SCHEDULE_OFFSET
  end

  def validate_prohibited_words!
    return if @options[:spoiler_text].blank? && @options[:text].blank?

    text = [@options[:spoiler_text], @options[:text]].join(' ')
    words = (@account&.user&.setting_prohibited_words || '').split(',').map(&:strip).filter(&:present?)

    raise Mastodon::ValidationError, I18n.t('status_prohibit.validations.prohibited_words') if words.any? { |word| text.include? word }
  end

  def validate_prohibited_visibilities!
    raise Mastodon::ValidationError, I18n.t('status_prohibit.validations.prohibited_visibilities') if @account.user&.setting_prohibited_visibilities&.filter(&:present?)&.include?(@visibility.to_s)
  end

  def validate_media!
    if @options[:media_ids].blank? || !@options[:media_ids].is_a?(Enumerable)
      @media = []
      return
    end

    raise Mastodon::ValidationError, I18n.t('media_attachments.validations.too_many') if @options[:media_ids].size > Setting.attachments_max || !Setting.allow_poll_image && @options[:poll].present?

    @media = @account.media_attachments.where(status_id: nil).where(id: @options[:media_ids].take(Setting.attachments_max).map(&:to_i))

    raise Mastodon::ValidationError, I18n.t('media_attachments.validations.images_and_video') if @media.size > 1 && @media.find(&:audio_or_video?)
    raise Mastodon::ValidationError, I18n.t('media_attachments.validations.not_ready') if @media.any?(&:not_processed?)
  end

  def validate_expires!
    return if @options[:expires_at].blank?

    @expires_at = @options[:expires_at].is_a?(Time) ? @options[:expires_at] : @options[:expires_at]&.to_time

    raise Mastodon::ValidationError, I18n.t('status_expire.validations.invalid_expire_at') if @expires_at.nil?
    raise Mastodon::ValidationError, I18n.t('status_expire.validations.expire_in_the_past') if @expires_at <= (@options[:scheduled_at]&.to_datetime&.to_time || Time.now.utc) + MIN_EXPIRE_OFFSET

    @expires_action = begin
      case @options[:expires_action]&.to_sym
      when :hint, :mark, nil
        :mark
      when :delete
        :delete
      else
        raise Mastodon::ValidationError, I18n.t('status_expire.validations.invalid_expire_action')
      end
    end
  end

  def language_from_option(str)
    ISO_639.find(str)&.alpha2
  end

  def scheduled?
    @scheduled_at.present?
  end

  def idempotency_key
    "idempotency:status:#{@account.id}:#{@options[:idempotency]}"
  end

  def idempotency_given?
    @options[:idempotency].present?
  end

  def idempotency_duplicate
    if scheduled?
      @account.scheduled_statuses.find(@idempotency_duplicate)
    else
      @account.statuses.find(@idempotency_duplicate)
    end
  end

  def idempotency_duplicate?
    @idempotency_duplicate = redis.get(idempotency_key)
  end

  def suspended_account
    nil
  end

  def scheduled_in_the_past?
    @scheduled_at.present? && @scheduled_at <= Time.now.utc
  end

  def bump_potential_friendship!
    return if !@status.reply? || @account.id == @status.in_reply_to_account_id
    ActivityTracker.increment('activity:interactions')
    return if @account.following?(@status.in_reply_to_account_id)
    PotentialFriendshipTracker.record(@account.id, @status.in_reply_to_account_id, :reply)
  end

  def status_attributes
    {
      text: @text,
      media_attachments: @media || [],
      ordered_media_attachment_ids: (@options[:media_ids] || []).map(&:to_i) & @media.map(&:id),
      thread: @in_reply_to,
      poll_attributes: poll_attributes,
      sensitive: @sensitive,
      spoiler_text: @options[:spoiler_text] || '',
      visibility: @visibility,
      circle: @circle,
      language: language_from_option(@options[:language]) || @account.user&.setting_default_language&.presence || LanguageDetector.instance.detect(@text, @account),
      application: @options[:application],
      rate_limit: @options[:with_rate_limit],
      quote_id: @quote_id,
      expires_at: @expires_at,
      expires_action: @expires_action,
      searchability: @searchability
    }.compact
  end

  def scheduled_status_attributes
    {
      scheduled_at: @scheduled_at,
      media_attachments: @media || [],
      params: scheduled_options,
    }
  end

  def poll_attributes
    return if @options[:poll].blank?

    @options[:poll].merge(account: @account, voters_count: 0)
  end

  def scheduled_options
    @options.dup.tap do |options_hash|
      options_hash[:in_reply_to_id]       = options_hash.delete(:thread)&.id
      options_hash[:application_id]       = options_hash.delete(:application)&.id
      options_hash[:scheduled_at]         = nil
      options_hash[:idempotency]          = nil
      options_hash[:status_reference_ids] = options_hash.delete(:status_reference_ids)&.map(&:to_s)&.filter{ |id| id != options_hash[:quote_id] }
      options_hash[:with_rate_limit]      = false
    end
  end
end
