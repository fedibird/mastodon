# frozen_string_literal: true

class Api::V1::CustomEmojisController < Api::BaseController
  include Redisable

  before_action :set_emoji, except: [:index, :fetch]
  vary_by '', unless: :disallow_unauthenticated_api_access?

  def index
    cache_even_if_authenticated! unless disallow_unauthenticated_api_access?
    render_with_cache(each_serializer: REST::CustomEmojiSerializer) { CustomEmoji.listed.includes(:category).reading_order }
  end

  def show
    render json: @custom_emoji, serializer: REST::CustomEmojiDetailSerializer
  end

  def fetch
    set_emoji(raise_error: false)

    if @custom_emoji.nil? || !@custom_emoji.local?
      RedisLock.acquire(lock_options) do |lock|
        if lock.acquired?
          if @custom_emoji&.possibly_stale?
            @custom_emoji.reload if ResolveURLService.new.call(@custom_emoji.uri, on_behalf_of: current_account)
          elsif @custom_emoji.nil?
            uri, id = CustomEmoji.find_by(domain: @domain).then {|c| [c&.uri, c&.shortcode]}
    
            if uri.present? && id.present?
              uri, id, suffix = uri.partition(id)
              uri = id.present? ? [uri, @shortcode, suffix].join : nil
            else
              uri = Addressable::URI.new(scheme: 'https', host: @domain, path: "/emojis/#{@shortcode}").normalize.to_s
            end
    
            @custom_emoji = ResolveURLService.new.call(uri, on_behalf_of: current_account)
            raise_not_found if @custom_emoji.nil?
          end
        else
          raise Mastodon::RaceConditionError
        end
      end
    end

    render json: @custom_emoji, serializer: REST::CustomEmojiDetailSerializer
  end

  private

  def set_emoji(raise_error: true)
    @shortcode, @domain = params[:id].split('@', 2)
    
    if @domain.nil? || @domain.casecmp(Rails.configuration.x.local_domain).zero?
      @custom_emoji = CustomEmoji.includes(:category).local.find_by("LOWER(shortcode) = ?", @shortcode.downcase) || CustomEmoji.includes(:category).local.find_by(id: params[:id])
    else
      @custom_emoji = CustomEmoji.includes(:category).find_by("LOWER(shortcode) = ? AND domain = ?", @shortcode.downcase, @domain)
    end

    raise ActiveRecord::RecordNotFound if @custom_emoji.nil? && raise_error
  end

  def lock_options
    { redis: redis, key: "fetch_custom_emoji:#{params[:id]}" }
  end
end
