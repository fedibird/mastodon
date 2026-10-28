# frozen_string_literal: true

module ExternalBridge
  module RSS
    # How one subscriber wants one article drawn. The shared resource is only
    # read. Sensitive media, the content warning, and language are independent.
    # Language comes from the subscriber's mode and the original title and
    # body, not from the warning or the generated excerpt. created_at is left
    # alone so a public-date change can set it without replacing language.
    module Presentation
      Fields = Struct.new(:text, :spoiler_text, :sensitive, :language, keyword_init: true)
      CONTROL = /[\p{Cc}\u2028\u2029]/.freeze

      module_function

      # The committed choices. Nil when the subscription is gone or fenced
      # for deletion, so a writer does not apply a display choice over a purge.
      def snapshot(subscription_id)
        row = ExternalSubscription.where(id: subscription_id).pick(
          :state, :media_sensitive, :cw_enabled, :language_mode, :language
        )
        return nil if row.nil? || row[0] == ExternalSubscription::DELETING

        {
          media_sensitive: row[1],
          cw_enabled: row[2],
          language_mode: row[3],
          language: row[4],
        }
      end

      def for(resource, media_sensitive:, cw_enabled:, language_mode: 'unspecified', language: nil)
        if cw_enabled
          spoiler = spoiler_for(resource)
          text = Excerpt.for(resource, spoiler_text: spoiler, omit_title: true)
        else
          spoiler = ''
          text = Excerpt.for(resource)
        end
        Fields.new(
          text: text,
          spoiler_text: spoiler,
          sensitive: media_sensitive == true,
          language: ArticleLanguage.for(resource, mode: language_mode, language: language)
        )
      end

      # Writes text, spoiler, sensitive, and language when they differ. Does
      # not change the status id, created_at, visibility, or any other
      # account's row, and does not publish an ActivityPub update. Returns
      # true when a column changed.
      def apply!(status, desired)
        changes = {}
        changes[:text] = desired.text if status.text != desired.text
        changes[:spoiler_text] = desired.spoiler_text if status.spoiler_text.to_s != desired.spoiler_text
        changes[:sensitive] = desired.sensitive if status.sensitive != desired.sensitive
        changes[:language] = desired.language if status.language != desired.language
        return false if changes.empty?

        status.update!(changes)
        Rails.cache.delete("statuses/#{status.id}")
        true
      end

      def changed?(status, desired)
        status.text != desired.text ||
          status.spoiler_text.to_s != desired.spoiler_text ||
          status.sensitive != desired.sensitive ||
          status.language != desired.language
      end

      # Plain text, one line, short enough that the body can still hold one
      # grapheme. StatusLengthValidator counts the spoiler and the body together.
      def spoiler_for(resource)
        text = plain(resource.title)
        text = I18n.t('external_bridge.untitled_article') if text.blank?
        text.each_grapheme_cluster.take(StatusLengthValidator::MAX_CHARS - 1).join
      end

      def plain(value)
        Rails::Html::FullSanitizer.new.sanitize(value.to_s).to_s.gsub(CONTROL, ' ').squish
      end
      private_class_method :plain
    end
  end
end
