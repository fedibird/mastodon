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

  # Accepts a Status, a prepared KeywordSubscribe::MatchingText, or a plain
  # String. A String is treated as the body, which keeps every legacy caller
  # working. The positive keyword and exclude_keyword are evaluated against the
  # very same prepared string, in both generated and raw regexp mode.
  def match?(target)
    text = matching_text_for(target)

    return false if keyword.blank? || !keyword_regexp.match?(text)
    return true if exclude_keyword.blank?

    !exclude_keyword_regexp.match?(text)
  end

  def keyword_regexp
    to_regexp keyword
  end

  def exclude_keyword_regexp
    to_regexp exclude_keyword
  end

  class << self
    def match?(target, account_id: nil, as_ignore_block: false, list_id: nil)
      text = KeywordSubscribe::MatchingText.wrap(target)

      scope = KeywordSubscribe.active.where(list_id: list_id)
      scope = scope.where(account_id: account_id) if account_id.present?
      scope = scope.ignore_block                  if as_ignore_block
      !scope.find { |t| t.match?(text) }.nil?
    end
  end

  private

  # The prepared string depends only on the status and on this subscription's two
  # options, so many subscriptions can share one KeywordSubscribe::MatchingText
  # and each combination is prepared at most once per status.
  def matching_text_for(target)
    KeywordSubscribe::MatchingText.wrap(target).text_for(match_hashtags: match_hashtags?, match_urls: match_urls?)
  end

  # Cached per keyword list, case option, and matching options, so one status
  # compared against many subscriptions does not rebuild the same pattern, and a
  # changed attribute cannot be served from the cache.
  def pattern_for(keywords)
    @patterns ||= {}
    @patterns[[keywords, ignorecase, match_hashtags?, match_urls?]] ||= pattern_builder.call(keywords)
  end

  # The legacy `(?<![#])` guard is dropped by either option: match_hashtags makes
  # hashtag material matchable on purpose, and match_urls makes `#` ordinary URL
  # material, such as the fragment in https://example.com/#foo.
  def pattern_builder
    KeywordSubscribe::PatternBuilder.new(
      ignorecase: ignorecase,
      hashtag_guard: !match_hashtags? && !match_urls?,
      punctuation_guard: !match_urls?
    )
  end

  def split_keywords(words)
    words.to_s.split(',')
  end

  def keyword_normalization(val)
    val.to_s.strip.gsub(/\s{2,}/, ' ').split(/\s*,\s*/).reject(&:blank?).uniq.join(',')
  end

  # A raw regexp keeps its source byte for byte. Only the string it is matched
  # against is prepared by the two options.
  def to_regexp(words)
    return Regexp.new(words, ignorecase, timeout: KeywordSubscribe::PatternBuilder::MATCH_TIMEOUT) if regexp

    pattern_for(split_keywords(words))
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
