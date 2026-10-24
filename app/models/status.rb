# frozen_string_literal: true
# == Schema Information
#
# Table name: statuses
#
#  id                           :bigint(8)        not null, primary key
#  uri                          :string
#  text                         :text             default(""), not null
#  created_at                   :datetime         not null
#  updated_at                   :datetime         not null
#  in_reply_to_id               :bigint(8)
#  reblog_of_id                 :bigint(8)
#  url                          :string
#  sensitive                    :boolean          default(FALSE), not null
#  visibility                   :integer          default("public"), not null
#  spoiler_text                 :text             default(""), not null
#  reply                        :boolean          default(FALSE), not null
#  language                     :string
#  conversation_id              :bigint(8)
#  local                        :boolean
#  account_id                   :bigint(8)        not null
#  application_id               :bigint(8)
#  in_reply_to_account_id       :bigint(8)
#  poll_id                      :bigint(8)
#  deleted_at                   :datetime
#  quote_id                     :bigint(8)
#  expired_at                   :datetime
#  searchability                :integer
#  generator_id                 :bigint(8)
#  ordered_media_attachment_ids :bigint(8)        is an Array
#  edited_at                    :datetime
#  trendable                    :boolean
#  audience_account_id          :bigint(8)
#  post_title                   :text
#  ap_object_type               :string
#  external_projection          :boolean
#

class Status < ApplicationRecord
  class UnreleasedActivityObject < StandardError; end

  before_destroy :unlink_from_conversations

  include Discard::Model
  include Paginable
  include Cacheable
  include StatusThreadingConcern
  include RateLimitable
  include Redisable
  include StatusSnapshotConcern
  include StatusTrendReview

  extend OrderAsSpecified

  rate_limit by: :account, family: :statuses

  self.discard_column = :deleted_at

  after_discard :notify_link_boost_wrapper_removed, if: :reblog_of_id?

  # If `override_timestamps` is set at creation time, Snowflake ID creation
  # will be based on current time instead of `created_at`
  attr_accessor :override_timestamps, :circle, :expires_at, :expires_action, :fetch

  update_index('statuses', :proper, if: :search_indexable?)

  # external (201) is the internal visibility for a private external-content
  # projection. It is not a composable or searchable visibility. Integer order
  # is not an authorization ranking.
  enum visibility: { public: 0, unlisted: 1, private: 2, direct: 3, limited: 4, mutual: 100, personal: 200, external: 201 }, _suffix: :visibility
  enum searchability: { public: 0, unlisted: 1, private: 2, direct: 3, limited: 4, mutual: 100, personal: 200 }, _suffix: :searchability

  STANDARD_VISIBILITY = %w(public unlisted private direct)
  FOLLOWER_VISIBILITY = %w(public unlisted private)
  EXTRA_VISIBILITY    = %w(limited personal)
  PSEUDO_VISIBILITY   = %w(mutual)
  UNCOUNT_VISIBILITY  = %w(direct personal external)

  # ActivityPub object type stored for a future Page. NULL means note.
  # This is not Status#object_type, which only distinguishes note and comment URIs.
  AP_OBJECT_TYPES = %w(note page).freeze
  AP_OBJECT_TYPE_NOTE = 'note'
  AP_OBJECT_TYPE_PAGE = 'page'
  # Unicode code points, the same count as PostgreSQL char_length and Ruby String#length.
  # Lemmy truncates at 200 scalar values. PieFed stores varchar(255). 100 stays under both.
  POST_TITLE_MAX_CODEPOINTS = 100
  POST_TITLE_CONTROL = /[\p{Cc}\u2028\u2029]/.freeze

  belongs_to :application, class_name: 'Doorkeeper::Application', optional: true
  belongs_to :generator, optional: true, inverse_of: :statuses

  belongs_to :account, inverse_of: :statuses
  belongs_to :in_reply_to_account, foreign_key: 'in_reply_to_account_id', class_name: 'Account', optional: true
  belongs_to :audience_account, class_name: 'Account', optional: true
  belongs_to :conversation, optional: true, inverse_of: :statuses
  belongs_to :preloadable_poll, class_name: 'Poll', foreign_key: 'poll_id', optional: true

  has_one :owned_conversation, class_name: 'Conversation', foreign_key: 'parent_status_id', inverse_of: :parent_status

  belongs_to :thread, foreign_key: 'in_reply_to_id', class_name: 'Status', inverse_of: :replies, optional: true
  belongs_to :reblog, foreign_key: 'reblog_of_id', class_name: 'Status', inverse_of: :reblogs, optional: true
  belongs_to :quote, foreign_key: 'quote_id', class_name: 'Status', inverse_of: :quoted, optional: true

  has_many :favourites, inverse_of: :status, dependent: :destroy
  has_many :bookmarks, inverse_of: :status, dependent: :destroy
  has_many :emoji_reactions, -> { enabled }, inverse_of: :status, dependent: :destroy
  has_many :reblogs, foreign_key: 'reblog_of_id', class_name: 'Status', inverse_of: :reblog, dependent: :destroy
  has_many :reblogged_by_accounts, through: :reblogs, class_name: 'Account', source: :account
  has_many :replies, foreign_key: 'in_reply_to_id', class_name: 'Status', inverse_of: :thread
  has_many :mentions, dependent: :destroy, inverse_of: :status
  has_many :active_mentions, -> { active }, class_name: 'Mention', inverse_of: :status
  has_many :media_attachments, dependent: :nullify
  has_many :quoted, foreign_key: 'quote_id', class_name: 'Status', inverse_of: :quote, dependent: :nullify
  has_many :capability_tokens, class_name: 'StatusCapabilityToken', inverse_of: :status, dependent: :destroy

  has_and_belongs_to_many :tags
  has_and_belongs_to_many :preview_cards

  has_many :reference_relationships, class_name: 'StatusReference', foreign_key: :status_id, dependent: :destroy
  has_many :references, through: :reference_relationships, source: :target_status
  has_many :referred_by_relationships, class_name: 'StatusReference', foreign_key: :target_status_id, dependent: :destroy
  has_many :referred_by, through: :referred_by_relationships, source: :status
  has_one :unresolve_status_reference_param, inverse_of: :status, dependent: :destroy

  has_one :notification, as: :activity, dependent: :destroy
  has_one :external_status_projection, inverse_of: :status, dependent: :restrict_with_exception
  has_one :status_stat, inverse_of: :status
  has_one :trend, class_name: 'StatusTrend', inverse_of: :status, dependent: :destroy
  has_one :poll, inverse_of: :status, dependent: :destroy
  has_one :status_expire, inverse_of: :status

  validates :uri, uniqueness: true, presence: true, unless: :local?
  validates :text, presence: true, unless: -> { with_media? || reblog? }
  validates_with StatusLengthValidator
  validates_with DisallowedHashtagsValidator
  validates :reblog, uniqueness: { scope: :account }, if: :reblog?
  validates :visibility, exclusion: { in: %w(direct) }, if: :reblog?
  validates :quote_visibility, inclusion: { in: %w(public unlisted) }, if: :quote?
  validates_with ExpiresValidator, on: :create, if: :local?
  validate :validate_post_title_shape
  validate :validate_ap_object_type_value
  validate :validate_page_activity_shape
  validate :validate_external_visibility_shape, on: [:create, :update]

  accepts_nested_attributes_for :poll

  before_validation :normalize_post_title_attribute

  default_scope { recent.kept.not_expired }

  scope :recent, -> { reorder(id: :desc) }
  scope :remote, -> { where(local: false).where.not(uri: nil) }
  scope :local,  -> { where(local: true).or(where(uri: nil)) }

  scope :expired, -> { where.not(expired_at: nil) }
  scope :not_expired, -> { where(expired_at: nil) }
  scope :include_expired, -> { unscoped.recent.kept }
  scope :with_accounts, ->(ids) { where(id: ids).includes(:account) }
  scope :without_replies, -> { where('statuses.reply = FALSE OR statuses.in_reply_to_account_id = statuses.account_id') }
  scope :without_reblogs, -> { where('statuses.reblog_of_id IS NULL') }
  # Wrapper boosts that stand for an E4-B link share are federation-only.
  # The reference note already holds the local timeline and profile slot, so
  # a feed or profile query that rebuilds from statuses leaves them out.
  scope :without_link_boost_wrappers, -> { where('statuses.reblog_of_id IS NULL OR NOT EXISTS (SELECT 1 FROM external_projection_link_boosts link_boost_wrappers WHERE link_boost_wrappers.wrapper_status_id = statuses.id)') }
  scope :with_public_visibility, -> { where(visibility: :public) }
  scope :with_personal_visibility, -> { where(visibility: :personal) }
  scope :without_personal_visibility, -> { where.not(visibility: :personal) }
  scope :counting_visibility, -> { where.not(visibility: UNCOUNT_VISIBILITY) }
  scope :tagged_with, ->(tag_ids) { joins(:statuses_tags).where(statuses_tags: { tag_id: tag_ids }) }
  scope :in_chosen_languages, ->(account) { where(language: nil).or where(language: account.chosen_languages) }
  scope :mentioned_with, ->(account) { joins(:mentions).where(mentions: { account_id: account }) }
  scope :excluding_silenced_accounts, -> { left_outer_joins(:account).where(accounts: { silenced_at: nil }) }
  scope :including_silenced_accounts, -> { left_outer_joins(:account).where.not(accounts: { silenced_at: nil }) }
  scope :not_excluded_by_account, ->(account) { where.not(account_id: account.excluded_from_timeline_account_ids) }
  scope :not_domain_blocked_by_account, ->(account) { account.excluded_from_timeline_domains.blank? ? left_outer_joins(:account) : left_outer_joins(:account).where('accounts.domain IS NULL OR accounts.domain NOT IN (?)', account.excluded_from_timeline_domains) }
  scope :tagged_with_all, ->(tag_ids) {
    Array(tag_ids).reduce(self) do |result, id|
      result.joins("INNER JOIN statuses_tags t#{id} ON t#{id}.status_id = statuses.id AND t#{id}.tag_id = #{id}")
    end
  }
  scope :tagged_with_none, ->(tag_ids) {
    Array(tag_ids).reduce(self) do |result, id|
      result.joins("LEFT OUTER JOIN statuses_tags t#{id} ON t#{id}.status_id = statuses.id AND t#{id}.tag_id = #{id}")
            .where("t#{id}.tag_id IS NULL")
    end
  }
  scope :unset_searchability, -> { where(searchability: nil, reblog_of_id: nil) }
  scope :indexable, -> { without_reblogs.where(visibility: :public).joins(:account).where(account: { indexable: true }) }
  scope :list_eligible_visibility, -> { where(visibility: %i(public unlisted private)) }
  # One residual predicate. It is not part of default_scope, so note queries
  # keep their existing indexes and only drop a stored page at the call site.
  scope :without_unreleased_pages, -> { where("#{table_name}.ap_object_type IS DISTINCT FROM 'page'") }

  cache_associated :application,
                   :media_attachments,
                   :conversation,
                   :status_stat,
                   :status_expire,
                   :preview_cards,
                   :preloadable_poll,
                   :generator,
                   :external_status_projection,
                   tags: [:tag_account_mute_relationships],
                   references: { account: :account_stat },
                   account: [:account_stat, :user],
                   active_mentions: { account: :account_stat },
                   reblog: [
                     :application,
                     :preview_cards,
                     :media_attachments,
                     :conversation,
                     :status_stat,
                     :status_expire,
                     :preloadable_poll,
                     :external_status_projection,
                     tags: [:tag_account_mute_relationships],
                     references: { account: :account_stat },
                     account: [:account_stat, :user],
                     active_mentions: { account: :account_stat },
                   ],
                   thread: { account: :account_stat }

  delegate :domain, to: :account, prefix: true

  REAL_TIME_WINDOW = 6.hours

  def searchable_by(preloaded = nil)
    ids = []

    ids << account_id if local?

    if preloaded.nil?
      ids += mentions.where(account: Account.local, silent: false).pluck(:account_id)
      ids += favourites.where(account: Account.local).pluck(:account_id)
      ids += reblogs.where(account: Account.local).pluck(:account_id)
      ids += bookmarks.where(account: Account.local).pluck(:account_id)
      ids += poll.votes.where(account: Account.local).pluck(:account_id) if poll.present?
      ids += emoji_reactions.where(account: Account.local).pluck(:account_id)
      ids += referred_by_statuses.where(account: Account.local).pluck(:account_id)
    else
      ids += preloaded.mentions[id] || []
      ids += preloaded.favourites[id] || []
      ids += preloaded.reblogs[id] || []
      ids += preloaded.bookmarks[id] || []
      ids += preloaded.votes[id] || []
      ids += preloaded.emoji_reactions[id] || []
      ids += preloaded.status_references[id] || []
    end

    ids.uniq
  end

  def mentioned_account_id(preloaded = nil)
    if preloaded.nil?
      mentions.pluck(:account_id)
    else
      preloaded.mentioned_account_ids[id] || []
    end
  end

  def trendable?
    if attributes['trendable'].nil?
      account.trendable?
    else
      attributes['trendable']
    end
  end

  def requires_review?
    attributes['trendable'].nil? && account.requires_review?
  end

  def requires_review_notification?
    attributes['trendable'].nil? && account.requires_review_notification?
  end

  def public_reblogged_by_account_id(preloaded = nil)
    if preloaded.nil?
      reblogs.where(visibility: 'public').map(&:account_id)
    else
      preloaded.public_reblogged_by_account_ids[id] || []
    end
  end

  def private_reblogged_by_account_id(preloaded = nil)
    if preloaded.nil?
      reblogs.where(visibility: ['unlisted', 'private']).map(&:account_id)
    else
      preloaded.private_reblogged_by_account_ids[id] || []
    end
  end

  def searchable_properties
    [].tap do |properties|
      properties << 'image' if media_attachments.any?(&:image?)
      properties << 'video' if media_attachments.any?(&:video?)
      properties << 'audio' if media_attachments.any?(&:audio?)
      properties << 'media' if with_media?
      properties << 'poll' if with_poll?
      properties << 'link' if with_preview_card?
      properties << 'embed' if preview_cards.any?(&:video?)
      properties << 'sensitive' if sensitive?
      properties << 'reply' if reply?
      properties << 'quote' if quote?
      properties << 'ref' if ref?
      properties << 'bot' if bot?
      properties << 'expired' if expired?
      properties << visibility
    end
  end

  def compute_searchability
    return 'personal' if external_visibility?

    searchability || Status.searchabilities.invert.fetch([Account.searchabilities[account.searchability], Status.visibilities[compatible_visibility] || 0].max, nil) || 'direct'
  end

  def standard_visibility?
    STANDARD_VISIBILITY.include?(visibility)
  end

  def follower_visibility?
    FOLLOWER_VISIBILITY.include?(visibility)
  end

  def extra_visibility?
    EXTRA_VISIBILITY.include?(visibility)
  end

  def pseudo_visibility?
    PSEUDO_VISIBILITY.include?(visibility)
  end

  def uncount_visibility?
    UNCOUNT_VISIBILITY.include?(visibility)
  end

  def compatible_visibility
    account.node&.info&.fetch('upstream_name', '') == 'misskey' && unlisted_visibility? ? 'public' : visibility
  end

  def reply?
    !in_reply_to_id.nil? || attributes['reply']
  end

  def local?
    attributes['local'] || uri.nil?
  end

  def in_reply_to_local_account?
    reply? && thread&.account&.local?
  end

  def reblog?
    !reblog_of_id.nil? && reblog
  end

  def quote?
    !quote_id.nil? && quote
  end

  def ref?
    references.present? && (!quote? || (references.map(&:url) - [quote.url])&.present?)
  end

  def emoji_reaction?
    status_stat&.emoji_reactions_cache.present?
  end

  def quote_visibility
    quote&.visibility
  end

  def mentioning?(source_account_id)
    source_account_id = source_account_id.id if source_account_id.is_a?(Account)

    mentions.where(account_id: source_account_id).exists?
  end

  def within_realtime_window?
    created_at >= REAL_TIME_WINDOW.ago
  end

  def verb
    if destroyed?
      :delete
    else
      reblog? ? :share : :post
    end
  end

  # URI discriminator used by the tag managers. A non-reply stays :note even
  # when ap_object_type is page, so Create, Update, and Delete keep one object id.
  def object_type
    reply? ? :comment : :note
  end

  def ap_object_type
    super.presence || AP_OBJECT_TYPE_NOTE
  end

  def ap_object_type=(value)
    normalized = value.to_s.presence
    super(normalized == AP_OBJECT_TYPE_NOTE ? nil : normalized)
  end

  def ap_page?
    self[:ap_object_type] == AP_OBJECT_TYPE_PAGE
  end

  def search_indexable?
    !ap_page? && external_projection != true && !external_visibility?
  end

  def self.normalize_post_title(value)
    return nil if value.nil?
    return value unless value.is_a?(String)
    return value if value.match?(POST_TITLE_CONTROL)

    stripped = value.gsub(/\A[[:space:]]+|[[:space:]]+\z/, '')
    stripped.empty? ? nil : stripped
  end

  def proper
    reblog? ? Status.include_expired.with_discarded.find(reblog_of_id) : self
  end

  def content
    proper.text
  end

  def target
    reblog
  end

  def preview_card
    preview_cards.first
  end

  def hidden?
    !distributable?
  end

  def distributable?
    public_visibility? || unlisted_visibility?
  end

  def public_safety?
    distributable? && (!with_media? || non_sensitive_with_media?) && !account.silenced? && !account.suspended?
  end

  def sign?
    distributable? || limited_visibility?
  end

  def with_media?
    media_attachments.present?
  end

  def with_preview_card?
    preview_cards.present?
  end

  def with_poll?
    preloadable_poll.present?
  end

  def expired?
    !expired_at.nil?
  end

  def expires?
    status_expire.present?
  end

  def expiry
    expires? && status_expire&.expires_mark? && status_expire&.expires_at || expired_at
  end

  def bookmarked?
    bookmarks.present?
  end

  def bot?
    account.bot?
  end

  def non_sensitive_with_media?
    !sensitive? && with_media?
  end

  def reported?
    @reported ||= Report.where(target_account: account).unresolved.where('? = ANY(status_ids)', id).exists?
  end

  def needs_fetch?
    unresolve_status_reference_param.present?
  end

  def emojis
    return @emojis if defined?(@emojis)

    fields  = [spoiler_text, text]
    fields += preloadable_poll.options unless preloadable_poll.nil?

    @emojis = CustomEmoji.from_text(fields.join(' '), account.domain) + (quote? ? CustomEmoji.from_text([quote.spoiler_text, quote.text].join(' '), quote.account.domain) : [])
  end

  def emojis_with_category
    emojis.tap { |emojis| ActiveRecord::Associations::Preloader.new.preload(emojis, :category) }
  end

  def urls
    @urls ||= ProcessStatusReferenceService.urls(self, urls: references.map(&:url))
  end

  def searchable_text
    @searchable_text ||= [
      spoiler_text.presence,
      Formatter.instance.plaintext(self).gsub(Regexp.union(urls), ' '),
      preloadable_poll ? preloadable_poll.options.join("\n\n") : nil,
      media_attachments.map(&:description).join("\n\n"),
    ].compact.join("\n\n")
  end

  def filterable_text
    @filterable_text ||= [
      searchable_text,
      filterable_urls.join("\n"),
    ].filter(&:present?).join("\n\n")
  end

  def filterable_urls
    index = filterable_reference_index

    canonical_urls = (
      urls.flat_map { |source_url| expand_filterable_source_url(source_url, index) } +
      references.flat_map { |reference| expanded_urls_for_reference(reference) }
    ).compact.uniq

    # Keep canonical URL forms and add the same human-readable representation
    # Formatter uses for link text, so a filter or a keyword written the way the
    # link reads matches a percent-encoded URL too. The display form never
    # replaces the canonical one and is never used as an identity.
    canonical_urls.flat_map { |url| [url, Formatter.instance.display_url(url)] }.uniq
  end

  def searchable_text_without_urls
    @searchable_text_without_urls ||= searchable_text.gsub(Regexp.union(urls), ' ')
  end

  def ordered_media_attachments
    if ordered_media_attachment_ids.nil?
      media_attachments
    else
      map = media_attachments.index_by(&:id)
      ordered_media_attachment_ids.filter_map { |media_attachment_id| map[media_attachment_id] }
    end
  end

  def replies_count
    status_stat&.replies_count || 0
  end

  def reblogs_count
    status_stat&.reblogs_count || 0
  end

  def favourites_count
    status_stat&.favourites_count || 0
  end

  def emoji_reactions_count
    @emoji_reactions_count || status_stat&.emoji_reactions_count || 0
  end

  def status_references_count
    status_stat&.status_references_count || 0
  end

  def status_referred_by_count
    status_stat&.status_referred_by_count || 0
  end

  def status_stat_updated_at
    status_stat&.updated_at
  end

  def account_ids(recursive: true)
    ids = [account_id.to_s]

    if recursive
      ids.concat(quote.account_ids(recursive: false)) unless quote.nil?
      ids.concat(reblog.account_ids(recursive: false)) unless reblog.nil?
      ids.concat(reblog.quote.account_ids(recursive: false)) unless reblog&.quote.nil?
    end

    ids.uniq
  end

  def grouped_emoji_reactions(account = nil)
    cache = status_stat&.emoji_reactions_cache

    (Oj.load(cache || '', mode: :strict) || []).then do |emoji_reactions|
      @emoji_reactions_count = 0

      emoji_reactions.filter do |emoji_reaction|
        if account.present?
          emoji_reaction['me'] = emoji_reaction['account_ids'].include?(account.id.to_s)
          emoji_reaction['account_ids'] -= (account.excluded_from_timeline_account_ids + Account.where(id: emoji_reaction['account_ids'], domain: account.excluded_from_timeline_domains).pluck(:id) + (Account.excluded_silenced_account_ids - [account.id])).uniq.map(&:to_s)
        else
          emoji_reaction['me'] = false
          emoji_reaction['account_ids'] -= Account.excluded_silenced_account_ids.map(&:to_s)
        end

        emoji_reaction['count'] = emoji_reaction['account_ids'].size
        @emoji_reactions_count += emoji_reaction['count']

        emoji_reaction['count'] > 0
      end
    end
  end

  def generate_grouped_emoji_reactions
    records = emoji_reactions.group(:name).order(Arel.sql('MIN(created_at) ASC')).select('name, min(custom_emoji_id) as custom_emoji_id, count(*) as count, array_agg(account_id::text order by created_at) as account_ids').limit(EmojiReactionValidator::LIMIT)
    ActiveRecord::Associations::Preloader.new.preload(records, :custom_emoji)
    Oj.dump(ActiveModelSerializers::SerializableResource.new(records, each_serializer: REST::GroupedEmojiReactionSerializer, scope: nil, scope_name: :current_user))
  end

  def mark_grouped_emoji_reactions_dirty!
    EmojiReactionCacheInvalidator.mark_status!(id)
    association(:status_stat).reset
  end

  # Authoritative rebuild. `force: false` is a no-op when the row is clean.
  # Generation, the count, and clearing dirty share one row lock so a mutation
  # that marks the row while this rebuild runs cannot be overwritten by a
  # stale dirty=false.
  def refresh_grouped_emoji_reactions!(force: true)
    stat = emoji_reaction_status_stat_for_refresh(force)
    return if stat.nil?

    stat.with_lock do
      next unless force || stat.emoji_reactions_cache_dirty?

      stat.update!(
        emoji_reactions_cache: generate_grouped_emoji_reactions,
        emoji_reactions_count: emoji_reactions.count,
        emoji_reactions_cache_dirty: false
      )
    end
  ensure
    association(:status_stat).reset
  end

  def refresh_grouped_emoji_reactions_if_dirty!
    refresh_grouped_emoji_reactions!(force: false)
  end

  def referred_by_statuses(account)
    statuses          = referred_by.includes(:account).to_a
    account_ids       = statuses.map(&:account_id).uniq
    account_relations = Status.relations_map_for_account(account, account_ids)
    status_relations  = Status.relations_map_for_status(account, statuses)

    decision = ExternalBridge::ProjectionAccess::Decision.for(statuses, ExternalBridge::Viewer.user_id)
    statuses.reject! do |status|
      StatusFilter.new(status, account, account_relations, status_relations, projection_decision: decision).filtered?
    end
    statuses.sort!.reverse!
  end

  def resolve_reference!
    unresolve_status_reference_param.tap do |param|
      ProcessStatusReferenceService.new.call(param.status, **param.options) if param.present?
      param&.destroy!
    end
  end

  def increment_count!(key)
    update_status_stat!(key => public_send(key) + 1)
  end

  def decrement_count!(key)
    update_status_stat!(key => [public_send(key) - 1, 0].max)
  end

  after_create_commit  :increment_counter_caches
  after_destroy_commit :decrement_counter_caches

  after_create_commit :store_uri, if: :local?
  after_create_commit :update_statistics, if: :local?
  after_create_commit :set_status_expire, if: -> { expires_at.present? }
  after_update :update_status_expire, if: -> { expires_at.present? }

  after_create_commit :trigger_create_webhooks
  after_update_commit :trigger_update_webhooks
  before_update :reject_external_projection_field_changes

  around_create Mastodon::Snowflake::Callbacks

  before_validation :prepare_contents, on: :create, if: :local?
  before_validation :set_reblog, on: :create
  before_validation :set_visibility, on: :create
  before_validation :set_searchability, on: :create
  before_validation :set_conversation, on: :create
  before_validation :set_local, on: :create

  after_create :set_poll_id
  after_create :set_circle

  class << self
    # Visibilities a person can store on a post, a posting style, or a filter.
    # external is internal and is never one of them.
    def composable_visibility_keys
      visibilities.keys - %w(external)
    end

    def composable_visibility?(value)
      value.is_a?(String) && composable_visibility_keys.include?(value)
    end

    def selectable_visibilities
      composable_visibility_keys - %w(direct limited)
    end

    def selectable_searchabilities
      searchabilities.keys - %w(unlisted limited mutual personal)
    end

    def favourites_map(status_ids, account_id)
      Favourite.select('status_id').where(status_id: status_ids).where(account_id: account_id).each_with_object({}) { |f, h| h[f.status_id] = true }
    end

    def bookmarks_map(status_ids, account_id)
      Bookmark.select('status_id').where(status_id: status_ids).where(account_id: account_id).map { |f| [f.status_id, true] }.to_h
    end

    def emoji_reactions_map(status_ids, account_id)
      EmojiReaction.select('status_id').where(status_id: status_ids).where(account_id: account_id).map { |f| [f.status_id, true] }.to_h
    end

    def reblogs_map(status_ids, account_id)
      unscoped.select('reblog_of_id').where(reblog_of_id: status_ids).where(account_id: account_id).each_with_object({}) { |s, h| h[s.reblog_of_id] = true }
    end

    def mutes_map(conversation_ids, account_id)
      ConversationMute.select('conversation_id').where(conversation_id: conversation_ids).where(account_id: account_id).each_with_object({}) { |m, h| h[m.conversation_id] = true }
    end

    def pins_map(status_ids, account_id)
      StatusPin.select('status_id').where(status_id: status_ids).where(account_id: account_id).each_with_object({}) { |p, h| h[p.status_id] = true }
    end

    def relations_map_for_account(account_id, account_ids)
      return {} if account_id.nil?

      presenter = AccountRelationshipsPresenter.new(account_ids, account_id)
      {
        blocking: presenter.blocking,
        blocked_by: presenter.blocked_by,
        muting: presenter.muting,
        following: presenter.following,
        subscribing: presenter.subscribing,
        domain_blocking_by_domain: presenter.domain_blocking,
      }
    end

    def relations_map_for_status(account_id, statuses)
      return {} if account_id.nil?

      presenter = StatusRelationshipsPresenter.new(statuses, account_id)
      {
        reblogs_map: presenter.reblogs_map,
        favourites_map: presenter.favourites_map,
        bookmarks_map: presenter.bookmarks_map,
        emoji_reactions_map: presenter.emoji_reactions_map,
        mutes_map: presenter.mutes_map,
        pins_map: presenter.pins_map,
      }
    end

    def permitted_statuses_from_ids(ids, account_id, viewer_user_id: ExternalBridge::Viewer.user_id)
      statuses          = Status.with_accounts(ids).includes(:external_status_projection).to_a
      account_ids       = statuses.map(&:account_id).uniq
      account_relations = relations_map_for_account(account_id, account_ids)
      status_relations  = relations_map_for_status(account_id, statuses)
      account           = Account.find_by(id: account_id)
      decision          = ExternalBridge::ProjectionAccess::Decision.for(statuses, viewer_user_id)

      statuses.reject! do |status|
        StatusFilter.new(status, account, account_relations, status_relations, projection_decision: decision).filtered?
      end
      statuses
    end

    def permitted_for(target_account, account)
      visibility = [:public, :unlisted]

      if account.nil?
        excluding_external_projections(where(visibility: visibility))
      elsif target_account.blocking?(account) || (account.domain.present? && target_account.domain_blocking?(account.domain)) # get rid of blocked peeps
        none
      elsif account.id == target_account.id # author can see own stuff
        # No user argument, so projections stay out of this scope.
        excluding_external_projections(all)
      else
        # followers can see followers-only stuff, but also things they are mentioned in.
        # non-followers can see everything that isn't private/direct, but can see stuff they are mentioned in.
        visibility.push(:private) if account.following?(target_account)

        scope = left_outer_joins(:reblog)

        excluding_external_projections(
          scope.where(visibility: visibility)
               .or(scope.where(id: account.mentions.select(:status_id)))
               .merge(scope.where(reblog_of_id: nil).or(scope.where.not(reblogs_statuses: { account_id: account.excluded_from_timeline_account_ids })))
        )
      end
    end

    def excluding_external_projections(relation)
      relation.where(Arel.sql(ExternalBridge::ProjectionPrivacy::NOT_PROJECTION_SQL))
    end

    def from_text(text)
      return [] if text.blank?

      text.scan(FetchLinkCardService::URL_PATTERN).map(&:first).uniq.filter_map do |url|
        status =
          if TagManager.instance.local_url?(url)
            ActivityPub::TagManager.instance.uri_to_resource(url, Status)
          else
            EntityCache.instance.status(url)
          end
        status&.distributable? ? status : nil
      end
    end
  end

  def status_stat
    super || build_status_stat
  end

  def tags_without_mute
    tags.merge(Tag.where.not(id: account.mute_tags.select(:id)))
  end

  def object_link
    quote? ? [ActivityPub::ObjectLinkPresenter.new(href: ActivityPub::TagManager.instance.uri_for(quote), name: "QT: #{ActivityPub::TagManager.instance.url_for(quote)}")] : []
  end

  private

  def normalize_post_title_attribute
    self.post_title = self.class.normalize_post_title(post_title)
  end

  def validate_post_title_shape
    return if post_title.nil?

    unless post_title.is_a?(String) && !post_title.match?(POST_TITLE_CONTROL)
      errors.add(:post_title, I18n.t('statuses.errors.post_title_invalid'))
      return
    end

    return if post_title.length <= POST_TITLE_MAX_CODEPOINTS

    errors.add(:post_title, I18n.t('statuses.errors.post_title_too_long', max: POST_TITLE_MAX_CODEPOINTS))
  end

  def validate_ap_object_type_value
    stored = self[:ap_object_type]
    return if stored.nil? || AP_OBJECT_TYPES.include?(stored)

    errors.add(:ap_object_type, I18n.t('statuses.errors.invalid_ap_object_type'))
  end

  def validate_external_visibility_shape
    return unless external_visibility?

    valid = external_projection == true &&
            uri.nil? &&
            personal_searchability? &&
            self[:local] == true &&
            reblog_of_id.nil? &&
            in_reply_to_id.nil? &&
            quote_id.nil? &&
            reply != true &&
            deleted_at.nil?
    return if valid

    errors.add(:base, I18n.t('external_bridge.errors.external_visibility_shape'))
  end

  def validate_page_activity_shape
    return unless ap_page?

    errors.add(:post_title, I18n.t('statuses.errors.page_title_required')) if post_title.blank?
    errors.add(:ap_object_type, I18n.t('statuses.errors.page_shape_unsupported')) if page_shape_unsupported?
  end

  def page_shape_unsupported?
    reblog_of_id.present? || reply? || quote_id.present? || poll_id.present? || poll.present? || !local?
  end

  def emoji_reaction_status_stat_for_refresh(force)
    stat = StatusStat.find_by(status_id: id)
    return stat if stat.present? && (!force || stat.emoji_reactions_cache_dirty?)
    return nil unless force

    EmojiReactionCacheInvalidator.mark_status!(id)
    StatusStat.find_by!(status_id: id)
  end

  def filterable_reference_index
    references.flat_map do |reference|
      [
        reference.url,
        reference.uri,
        ActivityPub::TagManager.instance.url_for(reference),
        ActivityPub::TagManager.instance.uri_for(reference),
      ].compact.map { |form| [form, reference] }
    end.to_h
  end

  def expand_filterable_source_url(source_url, index)
    reference = index[source_url]
    return [source_url] if reference.nil?

    expanded_urls_for_reference(reference, source_url)
  end

  def expanded_urls_for_reference(reference, source_url = nil)
    [
      ActivityPub::TagManager.instance.url_for(reference) || source_url,
      ActivityPub::TagManager.instance.uri_for(reference) || source_url,
    ]
  end

  def set_status_expire
    create_status_expire(expires_at: expires_at, action: expires_action)
  end

  def update_status_expire
    status_expire&.update(expires_at: expires_at, action: expires_action) || set_status_expire
  end

  def update_status_stat!(attrs)
    return if marked_for_destruction? || destroyed?

    status_stat.update(attrs)
  end

  def store_uri
    fresh = Status.find_by(id: id)
    return if fresh.nil? || fresh.uri.present?
    return if external_projection_side_effect?(fresh)

    uri_value = ActivityPub::TagManager.instance.uri_for(fresh)
    update_column(:uri, uri_value) if uri_value.present?
  end

  def reject_external_projection_field_changes
    return unless external_projection == true || external_visibility?

    protected_fields = %w(account_id visibility searchability uri external_projection deleted_at reblog_of_id in_reply_to_id quote_id)
    # local and reply are part of the external shape. Legacy personal
    # projections can still change them; ordinary posts never enter here.
    protected_fields |= %w(local reply) if external_visibility?
    return if (changed & protected_fields).empty?

    errors.add(:base, I18n.t('external_bridge.errors.projection_immutable'))
    throw :abort
  end

  def external_projection_side_effect?(fresh = nil)
    candidate = fresh || self
    return true if candidate.respond_to?(:external_visibility?) && candidate.external_visibility?
    return true if candidate.respond_to?(:external_projection) && candidate.external_projection == true

    status_id = candidate.respond_to?(:id) ? candidate.id : id
    return false if status_id.nil?

    ExternalStatusProjection.exists?(status_id: status_id)
  end

  def prepare_contents
    spoiler_text&.strip!
  end

  def set_reblog
    self.reblog = reblog.reblog if reblog? && reblog.reblog?
  end

  def set_poll_id
    update_column(:poll_id, poll.id) unless poll.nil?
  end

  def set_visibility
    self.visibility = reblog.visibility if reblog? && visibility.nil?
    self.visibility = (account.locked? ? :private : :public) if visibility.nil?
    self.sensitive  = false if sensitive.nil?
  end

  def set_searchability
    return if searchability.nil?
    # external is 201 and is not a searchability. Leave the assigned personal value.
    return if external_visibility?

    self.searchability = [Status.searchabilities[searchability], Status.visibilities[visibility]].max
  end

  def set_conversation
    self.thread = thread.reblog if thread&.reblog?

    self.reply = !(in_reply_to_id.nil? && thread.nil?) unless reply

    if reply? && !thread.nil?
      self.in_reply_to_account_id = carried_over_reply_to_account_id
    end

    if conversation_id.nil?
      if reply? && !thread.nil? && circle.nil?
        self.conversation_id = thread.conversation_id
      else
        build_owned_conversation
      end
    end
  end

  def set_circle
    redis.setex(circle_id_key, 3.days.seconds, circle.id) if circle.present?
  end

  def circle_id_key
    "statuses/#{id}/circle_id"
  end

  def carried_over_reply_to_account_id
    if thread.account_id == account_id && thread.reply?
      thread.in_reply_to_account_id
    else
      thread.account_id
    end
  end

  def set_local
    self.local = account.local?
  end

  def update_statistics
    return unless distributable?

    ActivityTracker.increment('activity:statuses:local')
  end

  def increment_counter_caches
    return if uncount_visibility? || ap_page?

    account&.touch_count!(:statuses_count) if fetch
    account&.increment_count!(:statuses_count) unless fetch
    reblog&.increment_count!(:reblogs_count) if reblog?
    thread&.increment_count!(:replies_count) if in_reply_to_id.present? && distributable?
  end

  def notify_link_boost_wrapper_removed
    ExternalBridge::LinkSharing::BoostEvents.wrapper_discarded!(id)
  end

  def decrement_counter_caches
    return if uncount_visibility? || new_record? || ap_page?

    account&.decrement_count!(:statuses_count)
    reblog&.decrement_count!(:reblogs_count) if reblog?
    thread&.decrement_count!(:replies_count) if in_reply_to_id.present? && distributable?
  end

  def unlink_from_conversations
    return if uncount_visibility?

    mentioned_accounts = (association(:mentions).loaded? ? mentions : mentions.includes(:account)).map(&:account)
    inbox_owners       = mentioned_accounts.select(&:local?) + (account.local? ? [account] : [])

    inbox_owners.each do |inbox_owner|
      AccountConversation.remove_status(inbox_owner, self)
    end
  end

  def trigger_create_webhooks
    return if external_projection_side_effect?
    TriggerWebhookWorker.perform_async('status.created', 'Status', id) if local? && !ap_page?
  end

  def trigger_update_webhooks
    return if external_projection_side_effect?
    TriggerWebhookWorker.perform_async('status.updated', 'Status', id) if local? && !ap_page?
  end
end
