# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Language stored on one subscriber's projected status.
    #
    # The shared resource is only read. Unspecified never calls the detector.
    # Auto uses the original title and body and does not fall back to the
    # viewer's interface language or default posting language. Fixed stores
    # the subscriber's code and ignores the article text.
    module ArticleLanguage
      MODES = %w(unspecified auto fixed).freeze

      module_function

      def for(resource, mode:, language:)
        return canonical(language) if mode.to_s == 'fixed'
        return detect(resource) if mode.to_s == 'auto'

        nil
      end

      # A supported code, or nil. Symbols are accepted from the detector.
      # Anything else, including an unknown or blank code, is nil.
      def canonical(code)
        text = case code
               when String then code
               when Symbol then code.to_s
               else
                 return
               end
        return if text.blank?
        return unless text.match?(/\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z/)
        return unless LanguagesHelper::SUPPORTED_LOCALES.key?(text.to_sym)

        text
      end

      def detect(resource)
        text = source_text(resource)
        return if text.blank?

        detected = LanguageDetector.instance.detect(text, nil, allow_fallback: false)
        canonical(detected)
      end

      # Title and body only. The projection excerpt adds the URL, the byline,
      # and stand-in wording; none of that is part of the article.
      def source_text(resource)
        [resource.title, resource.body].map(&:to_s).reject { |part| part.strip.blank? }.join("\n\n")
      end
    end
  end
end
