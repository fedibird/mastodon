# frozen_string_literal: true
# == Schema Information
#
# Table name: accounts
#
#  id                            :bigint(8)        not null, primary key
#  username                      :string           default(""), not null
#  domain                        :string
#  private_key                   :text
#  public_key                    :text             default(""), not null
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
#  note                          :text             default(""), not null
#  display_name                  :string           default(""), not null
#  uri                           :string           default(""), not null
#  url                           :string
#  avatar_file_name              :string
#  avatar_content_type           :string
#  avatar_file_size              :integer
#  avatar_updated_at             :datetime
#  header_file_name              :string
#  header_content_type           :string
#  header_file_size              :integer
#  header_updated_at             :datetime
#  avatar_remote_url             :string
#  locked                        :boolean          default(FALSE), not null
#  header_remote_url             :string           default(""), not null
#  last_webfingered_at           :datetime
#  inbox_url                     :string           default(""), not null
#  outbox_url                    :string           default(""), not null
#  shared_inbox_url              :string           default(""), not null
#  followers_url                 :string           default(""), not null
#  protocol                      :integer          default("ostatus"), not null
#  memorial                      :boolean          default(FALSE), not null
#  moved_to_account_id           :bigint(8)
#  featured_collection_url       :string
#  fields                        :jsonb
#  actor_type                    :string
#  discoverable                  :boolean
#  also_known_as                 :string           is an Array
#  silenced_at                   :datetime
#  suspended_at                  :datetime
#  trust_level                   :integer
#  hide_collections              :boolean
#  avatar_storage_schema_version :integer
#  header_storage_schema_version :integer
#  devices_url                   :string
#  suspension_origin             :integer
#  sensitized_at                 :datetime
#  settings                      :jsonb            default({}), not null
#  silence_mode                  :integer          default(0), not null
#  searchability                 :integer          default(3), not null
#  featured_tags_collection_url  :string
#  avatar_thumbhash              :string
#  header_thumbhash              :string
#  indexable                     :boolean          default(FALSE), not null
#  priority                      :integer          default(0), not null
#

class Account < ApplicationRecord
  self.ignored_columns = %w(
    subscription_expires_at
    secret
    remote_url
    salmon_url
    hub_url
  )

  USERNAME_RE   = /[a-z0-9_]+([.-]+[a-z0-9_]+)*/i
  MENTION_RE    = %r{(?<![=/[:word:]])@((#{USERNAME_RE})(?:@[[:word:]]+([.-]+[[:word:]]+)*)?)}
  URL_PREFIX_RE = %r{\Ahttp(s?)://[^/]+}
  USERNAME_ONLY_RE = /\A#{USERNAME_RE}\z/i

  DEFAULT_FIELDS_SIZE = 8

  HIDDEN_OTHER_SETTING_KEYS = %w(
    followed_message
  )

  include Attachmentable
  include AccountAssociations
  include AccountAvatar
  include AccountFinderConcern
  include AccountHeader
  include AccountInteractions
  include Paginable
  include AccountCounters
  include DomainNormalizable
  include DomainMaterializable
  include AccountMerging
  include AccountSettings
  include AccountStatusesSearch

  extend OrderAsSpecified

  TRUST_LEVELS = {
    untrusted: 0,
    trusted: 1,
  }.freeze

  enum protocol: [:ostatus, :activitypub]
  enum suspension_origin: [:local, :remote], _prefix: true
  enum silence_mode: { soft: 0, hard: 1 }, _suffix: :silence_mode
  enum searchability: { public: 0, unlisted: 1, private: 2, direct: 3, limited: 4, mutual: 100, personal: 200 }, _suffix: :searchability
  enum priority: { default: 0, high: 1, low: 2 }, _suffix: true

  validates :username, presence: true
  validates_with UniqueUsernameValidator, if: -> { will_save_change_to_username? }

  # Remote user validations
  validates :username, format: { with: /\A#{USERNAME_RE}\z/i }, if: -> { !local? && will_save_change_to_username? }

  # Local user validations
  validates :username, format: { with: /\A[a-z0-9_]+\z/i }, length: { maximum: 30 }, if: -> { local? && will_save_change_to_username? && actor_type != 'Application' }
  validates_with UnreservedUsernameValidator, if: -> { local? && will_save_change_to_username? }
  validates_with LocalDisplayNameValidator, if: -> { local? && will_save_change_to_display_name? }
  validates :note, note_length: { maximum: 500 }, if: -> { local? && will_save_change_to_note? }
  validates :fields, length: { maximum: DEFAULT_FIELDS_SIZE }, if: -> { local? && will_save_change_to_fields? }

  scope :remote, -> { where.not(domain: nil) }
  scope :local, -> { where(domain: nil) }
  scope :partitioned, -> { order(Arel.sql('row_number() over (partition by domain)')) }
  scope :silenced, -> { where.not(silenced_at: nil) }
  scope :soft_silenced, -> { where.not(silenced_at: nil).where(silence_mode: :soft) }
  scope :hard_silenced, -> { where.not(silenced_at: nil).where(silence_mode: :hard) }
  scope :suspended, -> { where.not(suspended_at: nil) }
  scope :sensitized, -> { where.not(sensitized_at: nil) }
  scope :without_suspended, -> { where(suspended_at: nil) }
  scope :without_silenced, -> { where(silenced_at: nil) }
  scope :without_instance_actor, -> { where.not(id: -99) }
  scope :recent, -> { reorder(id: :desc) }
  scope :bots, -> { where(actor_type: %w(Application Service)) }
  scope :without_bots, -> { where.not(actor_type: %w(Application Service)) }
  scope :groups, -> { where(actor_type: 'Group') }
  scope :without_groups, -> { where.not(actor_type: 'Group') }
  scope :alphabetic, -> { order(domain: :asc, username: :asc) }
  scope :matches_username, ->(value) { where('lower((username)::text) LIKE lower(?)', "#{value}%") }
  scope :matches_display_name, ->(value) { where(arel_table[:display_name].matches("#{value}%")) }
  scope :matches_domain, ->(value) { where(arel_table[:domain].matches("%#{value}%")) }
  scope :without_unapproved, -> { left_outer_joins(:user).remote.or(left_outer_joins(:user).merge(User.approved.confirmed)) }
  scope :searchable, -> { without_unapproved.without_suspended.where(moved_to_account_id: nil) }
  scope :discoverable, -> { searchable.without_silenced.where(discoverable: true).joins(:account_stat) }
  scope :followable_by, ->(account) { joins(arel_table.join(Follow.arel_table, Arel::Nodes::OuterJoin).on(arel_table[:id].eq(Follow.arel_table[:target_account_id]).and(Follow.arel_table[:account_id].eq(account.id))).join_sources).where(Follow.arel_table[:id].eq(nil)).joins(arel_table.join(FollowRequest.arel_table, Arel::Nodes::OuterJoin).on(arel_table[:id].eq(FollowRequest.arel_table[:target_account_id]).and(FollowRequest.arel_table[:account_id].eq(account.id))).join_sources).where(FollowRequest.arel_table[:id].eq(nil)) }
  scope :by_recent_status, -> { order(Arel.sql('(case when account_stats.last_status_at is null then 1 else 0 end) asc, account_stats.last_status_at desc, accounts.id desc')) }
  scope :by_recent_sign_in, -> { order(Arel.sql('(case when users.current_sign_in_at is null then 1 else 0 end) asc, users.current_sign_in_at desc, accounts.id desc')) }
  scope :popular, -> { order('account_stats.followers_count desc') }
  scope :by_domain_and_subdomains, ->(domain) { where(domain: domain).or(where(arel_table[:domain].matches('%.' + domain))) }
  scope :not_excluded_by_account, ->(account) { where.not(id: account.excluded_from_timeline_account_ids) }
  scope :not_domain_blocked_by_account, ->(account) { where(arel_table[:domain].eq(nil).or(arel_table[:domain].not_in(account.excluded_from_timeline_domains))) }
  scope :software, ->(name) { where(domain: Node.software(name).select(:domain)) }
  scope :upstream, ->(name) { where(domain: Node.upstream(name).select(:domain)) }

  delegate :email,
           :unconfirmed_email,
           :current_sign_in_ip,
           :current_sign_in_at,
           :confirmed?,
           :approved?,
           :pending?,
           :disabled?,
           :unconfirmed_or_pending?,
           :role,
           :admin?,
           :moderator?,
           :staff?,
           :locale,
           :noindex?,
           :hide_network?,
           :hide_statuses_count?,
           :hide_followers_count?,
           :hide_following_count?,
           :hide_statuses_count_from_yourself?,
           :hide_followers_count_from_yourself?,
           :hide_following_count_from_yourself?,
           :hide_subscribing_count_from_yourself?,
           :shows_application?,
           to: :user,
           prefix: true,
           allow_nil: true

  delegate :chosen_languages, to: :user, prefix: false, allow_nil: true

  update_index('accounts', :self)

  # workaround
  def user_time_zone
    'Asia/Tokyo'
  end

  def local?
    domain.nil?
  end

  def moved?
    moved_to_account_id.present?
  end

  def newcommer?
    created_at > 7.days.ago
  end

  def bot?
    %w(Application Service).include? actor_type
  end

  def person_type?
    actor_type.blank? || actor_type == 'Person'
  end

  def service_type?
    actor_type == 'Service'
  end

  def group_type?
    actor_type == 'Group'
  end

  def person_type!
    update!(actor_type: 'Person')
  end

  def service_type!
    update!(actor_type: 'Service')
  end

  def group_type!
    update!(actor_type: 'Group')
  end

  def instance_actor?
    id == -99
  end

  alias bot bot?

  def bot=(val)
    return if group?

    self.actor_type = ActiveModel::Type::Boolean.new.cast(val) ? 'Service' : 'Person'
  end

  def group?
    actor_type == 'Group'
  end

  alias group group?

  def acct
    local? ? username : "#{username}@#{domain}"
  end

  def pretty_acct
    local? ? username : "#{username}@#{Addressable::IDNA.to_unicode(domain)}"
  end

  def local_username_and_domain
    "#{username}@#{Rails.configuration.x.local_domain}"
  end

  def public_statuses_count
    hide_statuses_count? ? 0 : statuses_count
  end

  def public_followers_count
    hide_followers_count? ? 0 : followers_count
  end

  def public_following_count
    hide_following_count? ? 0 : following_count
  end

  def local_followers_count
    Follow.where(target_account_id: id).count
  end

  def to_webfinger_s
    "acct:#{local_username_and_domain}"
  end

  def searchable?
    !(suspended? || moved?)
  end

  def possibly_stale?
    last_webfingered_at.nil? || last_webfingered_at <= 1.day.ago
  end

  def trust_level
    self[:trust_level] || 0
  end

  def refresh!
    ResolveAccountService.new.call(acct) unless local?
  end

  def silenced?
    silenced_at.present?
  end

  def silence!(date = Time.now.utc)
    update!(silenced_at: date, silence_mode: :soft)
  end

  def unsilence!
    update!(silenced_at: nil)
  end

  def hard_silenced?
    silenced_at.present? && hard_silence_mode?
  end

  def hard_silence!(date = Time.now.utc)
    update!(silenced_at: date, silence_mode: :hard)
  end

  def suspended?
    suspended_at.present? && !instance_actor?
  end

  def suspended_permanently?
    suspended? && deletion_request.nil?
  end

  def suspended_temporarily?
    suspended? && deletion_request.present?
  end

  def suspend!(date: Time.now.utc, origin: :local, block_email: true)
    transaction do
      create_deletion_request!
      update!(suspended_at: date, suspension_origin: origin)
      create_canonical_email_block! if block_email
    end
  end

  def unsuspend!
    transaction do
      deletion_request&.destroy!
      update!(suspended_at: nil, suspension_origin: nil)
      destroy_canonical_email_block!
    end
  end

  def sensitized?
    sensitized_at.present?
  end

  def sensitize!(date = Time.now.utc)
    update!(sensitized_at: date)
  end

  def unsensitize!
    update!(sensitized_at: nil)
  end

  def memorialize!
    update!(memorial: true)
  end

  def sign?
    true
  end

  def keypair
    @keypair ||= OpenSSL::PKey::RSA.new(private_key || public_key)
  end

  def tags_as_strings=(tag_names)
    hashtags_map = Tag.find_or_create_by_names(tag_names).index_by(&:name)

    # Remove hashtags that are to be deleted
    tags.each do |tag|
      if hashtags_map.key?(tag.name)
        hashtags_map.delete(tag.name)
      else
        tags.delete(tag)
      end
    end

    # Add hashtags that were so far missing
    hashtags_map.each_value do |tag|
      tags << tag
    end
  end

  def also_known_as
    self[:also_known_as] || []
  end

  def fields
    (self[:fields] || []).map do |f|
      Field.new(self, f)
    rescue
      nil
    end.compact
  end

  def fields_attributes=(attributes)
    fields     = []
    old_fields = self[:fields] || []
    old_fields = [] if old_fields.is_a?(Hash)

    if attributes.is_a?(Hash)
      attributes.each_value do |attr|
        next if attr[:name].blank?

        previous = old_fields.find { |item| item['value'] == attr[:value] }

        if previous && previous['verified_at'].present?
          attr[:verified_at] = previous['verified_at']
        end

        fields << attr
      end
    end

    self[:fields] = fields
  end

  def build_fields
    return if fields.size >= DEFAULT_FIELDS_SIZE

    tmp = self[:fields] || []
    tmp = [] if tmp.is_a?(Hash)

    (DEFAULT_FIELDS_SIZE - tmp.size).times do
      tmp << { name: '', value: '' }
    end

    self.fields = tmp
  end

  def save_with_optional_media!
    save!
  rescue ActiveRecord::RecordInvalid => e
    errors = e.record.errors.errors
    errors.each do |err|
      if err.attribute == :avatar
        self.avatar = nil
      elsif err.attribute == :header
        self.header = nil
      end
    end

    save!
  end

  def hide_followers?
    hide_collections? || hide_network?
  end

  def hide_following?
    hide_collections? || hide_network?
  end

  def object_type
    :person
  end

  def to_param
    username
  end

  def excluded_from_timeline_account_ids
    Rails.cache.fetch("exclude_account_ids_for:#{id}") { block_relationships.pluck(:target_account_id) + blocked_by_relationships.pluck(:account_id) + mute_relationships.pluck(:target_account_id) }
  end

  def excluded_from_timeline_domains
    Rails.cache.fetch("exclude_domains_for:#{id}") { domain_blocks.pluck(:domain) }
  end

  def inbox_url
    self[:inbox_url]
  end

  def preferred_inbox_url
    shared_inbox_url.presence || inbox_url
  end

  def synchronization_uri_prefix
    return 'local' if local?

    @synchronization_uri_prefix ||= "#{uri[URL_PREFIX_RE]}/"
  end

  def permitted_statuses(account)
    if account.class.name == 'Account' && account.id == id
      Status.include_expired.where(account_id: id)
    else
      statuses
    end.permitted_for(self, account)
  end

  def conversation_statuses(account)
    ids = Account.without_suspended.where.not(id: excluded_from_timeline_account_ids).where(Account.arel_table[:domain].eq(nil).or(Account.arel_table[:domain].not_in(excluded_from_timeline_domains))).select(:id)

    if account.nil? || account.class.name == 'Account' && account.id == id
      Status.unscoped.recent
      .union_all(Status.include_expired.joins(:mentions).where(account_id: id,  mentions: {account_id: ids, silent: false}))
      .union_all(Status.include_expired.joins(:mentions).where(account_id: ids, mentions: {account_id: id,  silent: false}))
    elsif account.suspended? || excluded_from_timeline_account_ids.include?(account.id) || account.domain.present? && excluded_from_timeline_domains.include?(account.domain)
      Status.none
    else
      Status.unscoped.recent
      .union_all(Status.include_expired.joins(:mentions).where(account_id: id, mentions: {silent: false, account_id: account.id}))
      .union_all(Status.include_expired.joins(:mentions).where(account_id: account.id, mentions: {account_id: id, silent: false}))
    end
  end

  def searchable_text
    ActionController::Base.helpers.strip_tags(note)
  end

  class Field < ActiveModelSerializers::Model
    attributes :name, :value, :verified_at, :account

    def initialize(account, attributes)
      @original_field = attributes
      string_limit = account.local? ? 255 : 2047
      super(
        account:     account,
        name:        attributes['name'].strip[0, string_limit],
        value:       attributes['value'].strip[0, string_limit],
        verified_at: attributes['verified_at']&.to_time,
      )
    end

    def verified?
      verified_at.present?
    end

    def value_for_verification
      @value_for_verification ||= begin
        if account.local?
          value
        else
          ActionController::Base.helpers.strip_tags(value)
        end
      end
    end

    def verifiable?
      value_for_verification.present? && value_for_verification.start_with?('http://', 'https://')
    end

    def mark_verified!
      self.verified_at = Time.now.utc
      @original_field['verified_at'] = verified_at
    end

    def to_h
      { name: name, value: value, verified_at: verified_at }
    end
  end

  class << self
    def readonly_attributes
      super - %w(statuses_count following_count followers_count)
    end

    def inboxes
      urls = reorder(nil).where(protocol: :activitypub).group(:preferred_inbox_url).pluck(Arel.sql("coalesce(nullif(accounts.shared_inbox_url, ''), accounts.inbox_url) AS preferred_inbox_url"))
      DeliveryFailureTracker.without_unavailable(urls)
    end

    def search_for(terms, limit = 10, group = false, offset = 0)
      textsearch, query = generate_query_for_search(terms)

      sql_where_group = <<-SQL if group
          AND accounts.actor_type = 'Group'
      SQL

      sql = <<-SQL.squish
        SELECT
          accounts.*,
          ts_rank_cd(#{textsearch}, #{query}, 32) AS rank
        FROM accounts
        WHERE #{query} @@ #{textsearch}
          AND accounts.suspended_at IS NULL
          AND accounts.moved_to_account_id IS NULL
          #{sql_where_group}
        ORDER BY rank DESC
        LIMIT :limit OFFSET :offset
      SQL

      records = find_by_sql([sql, { limit: limit, offset: offset }])
      ActiveRecord::Associations::Preloader.new.preload(records, :account_stat)
      records
    end

    def advanced_search_for(terms, account, limit = 10, offset = 0, options = {})
      textsearch, query = generate_query_for_search(terms)

      sql_where_group = <<-SQL if options[:group]
          AND accounts.actor_type = 'Group'
      SQL

      sql = if options[:following] || options[:followers]
              sql_first_degree = first_degree(options)

              <<-SQL.squish
                #{sql_first_degree}
                SELECT
                  accounts.*,
                  (count(f.id) + 1) * ts_rank_cd(#{textsearch}, #{query}, 32) AS rank
                FROM accounts
                LEFT OUTER JOIN follows AS f ON (accounts.id = f.account_id AND f.target_account_id = :account_id)
                WHERE accounts.id IN (SELECT * FROM first_degree)
                  AND #{query} @@ #{textsearch}
                  AND accounts.suspended_at IS NULL
                  AND accounts.moved_to_account_id IS NULL
                  #{sql_where_group}
                GROUP BY accounts.id
                ORDER BY rank DESC
                LIMIT :limit OFFSET :offset
              SQL
            else
              <<-SQL.squish
                SELECT
                  accounts.*,
                  (count(f.id) + 1) * ts_rank_cd(#{textsearch}, #{query}, 32) AS rank
                FROM accounts
                LEFT OUTER JOIN follows AS f ON (accounts.id = f.account_id AND f.target_account_id = :account_id) OR (accounts.id = f.target_account_id AND f.account_id = :account_id)
                WHERE #{query} @@ #{textsearch}
                  AND accounts.suspended_at IS NULL
                  AND accounts.moved_to_account_id IS NULL
                  #{sql_where_group}
                GROUP BY accounts.id
                ORDER BY rank DESC
                LIMIT :limit OFFSET :offset
              SQL
            end

      records = find_by_sql([sql, { account_id: account.id, limit: limit, offset: offset }])
      ActiveRecord::Associations::Preloader.new.preload(records, :account_stat)
      records
    end

    def from_text(text)
      return [] if text.blank?

      text.scan(MENTION_RE).map { |match| match.first.split('@', 2) }.uniq.filter_map do |(username, domain)|
        domain = begin
          if TagManager.instance.local_domain?(domain)
            nil
          else
            TagManager.instance.normalize_domain(domain)
          end
        end
        EntityCache.instance.mention(username, domain)
      end
    end

    def excluded_silenced_account_ids
      Rails.cache.fetch("excluded_silenced_account_ids") { Account.silenced.pluck(:id) }
    end

    private

    def first_degree(options)
      if options[:following] && options[:followers]
        <<-SQL
          WITH first_degree AS (
            SELECT target_account_id
            FROM follows
            WHERE account_id = :account_id
            UNION ALL
            SELECT account_id
            FROM follows
            WHERE target_account_id = :account_id
            UNION ALL
            SELECT :account_id
          )
        SQL
      elsif options[:following]
        <<-SQL
          WITH first_degree AS (
            SELECT target_account_id
            FROM follows
            WHERE account_id = :account_id
            UNION ALL
            SELECT :account_id
          )
        SQL
      elsif options[:followers]
        <<-SQL
          WITH first_degree AS (
            SELECT account_id
            FROM follows
            WHERE target_account_id = :account_id
            UNION ALL
            SELECT :account_id
          )
        SQL
      end
    end

    def generate_query_for_search(terms)
      terms      = Arel.sql(connection.quote(terms.gsub(/['?\\:]/, ' ')))
      textsearch = "(setweight(to_tsvector('simple', accounts.display_name), 'A') || setweight(to_tsvector('simple', accounts.username), 'B') || setweight(to_tsvector('simple', coalesce(accounts.domain, '')), 'C'))"
      query      = "to_tsquery('simple', ''' ' || #{terms} || ' ''' || ':*')"

      [textsearch, query]
    end
  end

  def emojis
    @emojis ||= CustomEmoji.from_text(emojifiable_text, domain)
  end

  def emojis_with_category
    emojis.tap { |emojis| ActiveRecord::Associations::Preloader.new.preload(emojis, :category) }
  end

  before_create :generate_keys
  before_validation :prepare_contents, if: :local?
  before_validation :prepare_username, on: :create
  before_destroy :clean_feed_manager

  private

  def prepare_contents
    display_name&.strip!
    note&.strip!
    followed_message&.strip!
  end

  def prepare_username
    username&.squish!
  end

  def generate_keys
    return unless local? && private_key.blank? && public_key.blank?

    keypair = OpenSSL::PKey::RSA.new(2048)
    self.private_key = keypair.to_pem
    self.public_key  = keypair.public_key.to_pem
  end

  def normalize_domain
    return if local?

    super
  end

  def emojifiable_text
    [note, display_name, followed_message, fields.map(&:name), fields.map(&:value)].join(' ')
  end

  def clean_feed_manager
    FeedManager.instance.clean_feeds!(:home, [id])
  end

  def create_canonical_email_block!
    return unless local? && user_email.present?

    begin
      CanonicalEmailBlock.create(reference_account: self, email: user_email)
    rescue ActiveRecord::RecordNotUnique
      # A canonical e-mail block may already exist for the same e-mail
    end
  end

  def destroy_canonical_email_block!
    return unless local?

    CanonicalEmailBlock.where(reference_account: self).delete_all
  end
end
