# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Language stored on a subscription the first time that row is created.
    #
    # The sample is the same window Subscribe imports: at most
    # Limits::MAX_ITEMS resources, ordered by published_at descending and
    # then id descending (the same clause Materialize uses, including the
    # database's ordering of null publication times). Older history is not
    # read. Each article is judged on its own title and body. The texts are
    # not joined into one detection.
    #
    # Empty text after LanguageDetector's cleanup is left out of the sample.
    # A reliable supported code comes from ArticleLanguage.detect, which
    # keeps allow_fallback false and does not use the viewer's locale.
    # Two or more distinct codes choose auto, even when another article in
    # the sample cannot be judged. One code chooses fixed only when every
    # remaining article has that code. Anything else stays unspecified,
    # including a single confident article beside text that cannot be judged.
    #
    # This is a guess from the first import page. It does not describe the
    # whole history or later articles, and one article still has one code.
    # The choice is written only on the new subscription, before its first
    # save and before the first projection. A later refresh does not repeat it.
    module InitialLanguage
      module_function

      def attributes_for(source)
        reliable = []
        content = 0

        sample_resources(source).each do |resource|
          verdict = classify(resource)
          next if verdict == :blank

          content += 1
          reliable << verdict if verdict.is_a?(String)
        end

        choice(reliable, content)
      end

      def sample_resources(source)
        source.external_resources.order(published_at: :desc, id: :desc).limit(Limits::MAX_ITEMS)
      end

      def classify(resource)
        text = ArticleLanguage.source_text(resource)
        return :blank if LanguageDetector.instance.prepared_text(text).blank?

        ArticleLanguage.detect(resource) || :unknown
      end

      def choice(reliable, content)
        distinct = reliable.uniq
        if distinct.size >= 2
          { language_mode: 'auto', language: nil }
        elsif distinct.size == 1 && reliable.size == content
          { language_mode: 'fixed', language: distinct.first }
        else
          { language_mode: 'unspecified', language: nil }
        end
      end
    end
  end
end
