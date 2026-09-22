# == Schema Information
#
# Table name: keyword_subscribes
#
#  id              :bigint(8)        not null, primary key
#  account_id      :bigint(8)
#  keyword         :string           not null
#  ignorecase      :boolean          default(TRUE)
#  regexp          :boolean          default(FALSE)
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  name            :string           default(""), not null
#  ignore_block    :boolean          default(FALSE)
#  disabled        :boolean          default(FALSE)
#  exclude_keyword :string           default(""), not null
#  list_id         :bigint(8)
#  media_only      :boolean          default(FALSE), not null
#  match_hashtags  :boolean          default(FALSE), not null
#  match_urls      :boolean          default(FALSE), not null
#

class KeywordSubscribe < ApplicationRecord
  belongs_to :account, inverse_of: :keyword_subscribes, required: true
  belongs_to :list, optional: true

  validates :keyword, presence: true
  validate :validate_subscribes_limit, on: :create
  validate :validate_keyword_regexp_syntax
  validate :validate_exclude_keyword_regexp_syntax
  validate :validate_uniqueness_in_account, on: :create

  scope :active, -> { where(disabled: false) }
  scope :ignore_block, -> { where(ignore_block: true) }
  scope :home, -> { where(list_id: nil) }
  scope :list, -> { where.not(list_id: nil) }
  scope :without_local_followed_home, ->(account) { home.where.not(account: account.delivery_followers.local) }
  scope :without_local_followed_list, ->(account) { list.where.not(list_id: ListAccount.followed_lists(account)) }
  scope :with_media, ->(status) { where(media_only: false) unless status.with_media? }

  def keyword=(val)
    super(regexp ? val : keyword_normalization(val))
  end

  def exclude_keyword=(val)
    super(regexp ? val : keyword_normalization(val))
  end

  # Accepts a Status, a prepared KeywordSubscribe::MatchingContexts, or a plain
  # String. A String is treated as the body channel, which keeps every legacy
  # caller working.
  def match?(target)
    contexts = KeywordSubscribe::MatchingContexts.wrap(target)

    return false unless match_words?(keyword, contexts)
    return true if exclude_keyword.empty?

    !match_words?(exclude_keyword, contexts)
  end

  def keyword_regexp
    to_regexp keyword
  end

  def exclude_keyword_regexp
    to_regexp exclude_keyword
  end

  class << self
    def match?(target, account_id: nil, as_ignore_block: false, list_id: nil)
      contexts = KeywordSubscribe::MatchingContexts.wrap(target)

      scope = KeywordSubscribe.active.where(list_id: list_id)
      scope = scope.where(account_id: account_id) if account_id.present?
      scope = scope.ignore_block                  if as_ignore_block
      !scope.find { |t| t.match?(contexts) }.nil?
    end
  end

  private

  # The body channel is always matched. The URL and hashtag channels are added
  # only by their own option, and exclude_keyword sees exactly the same set of
  # channels as the positive keyword.
  def match_words?(words, contexts)
    return false if words.blank?
    return match_raw?(words, contexts) if regexp

    match_generated?(words, contexts)
  end

  # Raw regexp mode keeps the legacy body behavior exactly: the source is
  # matched against searchable_text, hashtags included, because visible hashtag
  # text has always been part of that channel. The options only add channels.
  def match_raw?(words, contexts)
    pattern = to_regexp(words)

    return true if pattern.match?(contexts.body)
    return true if match_urls? && contexts.urls.any? { |url| pattern.match?(url) }
    return true if match_hashtags? && contexts.hashtag_tokens.any? { |token| pattern.match?(token) }

    false
  end

  # Generated keywords read the body with hashtag spans removed, so an ordinary
  # keyword cannot match somewhere inside a hashtag. A keyword that spells a
  # hash itself is an explicit hashtag keyword and keeps reading the raw body,
  # which preserves its legacy behavior.
  def match_generated?(words, contexts)
    keywords      = split_keywords(words)
    hashed, plain = keywords.partition { |k| k.include?('#') }

    return true if plain.any? && pattern_for(plain, :body).match?(contexts.body_without_hashtags)
    return true if hashed.any? && pattern_for(hashed, :body).match?(contexts.body)
    return true if match_urls? && contexts.urls.any? { |url| pattern_for(keywords, :url).match?(url) }
    return true if match_hashtags? && contexts.hashtag_tokens.any? { |token| pattern_for(keywords, :hashtag).match?(token) }

    false
  end

  # Cached per keyword list, context, and case option, so one status compared
  # against many subscriptions does not rebuild the same pattern, and a changed
  # attribute cannot be served from the cache.
  def pattern_for(keywords, context)
    @patterns ||= {}
    @patterns[[keywords, context, ignorecase]] ||= KeywordSubscribe::PatternBuilder.new(ignorecase: ignorecase).call(keywords, context)
  end

  def split_keywords(words)
    words.to_s.split(',')
  end

  def keyword_normalization(val)
    val.to_s.strip.gsub(/\s{2,}/, ' ').split(/\s*,\s*/).reject(&:blank?).uniq.join(',')
  end

  def to_regexp(words)
    return Regexp.new(words, ignorecase, timeout: KeywordSubscribe::PatternBuilder::MATCH_TIMEOUT) if regexp

    pattern_for(split_keywords(words), :body)
  end

  def validate_keyword_regexp_syntax
    return unless regexp

    begin
      Regexp.compile(keyword, ignorecase)
    rescue RegexpError => exception
      errors.add(:base, I18n.t('keyword_subscribes.errors.regexp', message: exception.message))
    end
  end

  def validate_exclude_keyword_regexp_syntax
    return unless regexp

    begin
      Regexp.compile(exclude_keyword, ignorecase)
    rescue RegexpError => exception
      errors.add(:base, I18n.t('keyword_subscribes.errors.regexp', message: exception.message))
    end
  end

  def validate_subscribes_limit
    errors.add(:base, I18n.t('keyword_subscribes.errors.limit')) if account.keyword_subscribes.count >= 100
  end

  def validate_uniqueness_in_account
    errors.add(:base, I18n.t('keyword_subscribes.errors.duplicate')) if account.keyword_subscribes.find_by(keyword: keyword, exclude_keyword: exclude_keyword, list_id: list_id)
  end
end
