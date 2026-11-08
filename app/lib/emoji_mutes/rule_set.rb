# frozen_string_literal: true

# One load of an account's mute rows, then in-memory checks. Callers must not
# issue another mute SELECT per status or per emoji.
class EmojiMutes::RuleSet
  EMPTY_RULES = [].freeze

  def self.for(account_id)
    return empty if account_id.nil?

    sets = EmojiMutes::Current.rule_sets ||= {}
    sets[account_id] ||= load(account_id)
  end

  def self.revision_for(account_id)
    return 0 if account_id.nil?

    revisions = EmojiMutes::Current.revisions ||= {}
    revisions[account_id] ||= EmojiMuteRevision.where(account_id: account_id).pick(:revision) || 0
  end

  def self.empty
    new(EMPTY_RULES)
  end

  def self.load(account_id)
    new(EmojiMute.where(account_id: account_id).to_a)
  end

  def initialize(rules)
    @rules = rules
    index!
  end

  def hides_any?
    @hide_unicode.any? || @hide_local.any? || @hide_remote.any?
  end

  def rejects?(name:, custom_emoji: nil, remote_domain: nil, shortcode: nil)
    if custom_emoji&.domain.present?
      remote_included?(@reject_remote, custom_emoji.shortcode, custom_emoji.domain)
    elsif remote_domain.present?
      remote_included?(@reject_remote, shortcode.presence || name, remote_domain)
    elsif custom_emoji&.local?
      @reject_local.include?(custom_emoji.id)
    else
      EmojiMutes::UnicodeMatch.same_in?(@reject_unicode, name)
    end
  end

  def hides_part?(part)
    return false unless part.is_a?(Hash)

    if part['custom_emoji_id'].blank? && part['domain'].blank?
      return @hide_unicode.include?(part['native'].presence || part['name'])
    end

    if part['domain'].present?
      return remote_included?(@hide_remote, part['shortcode'], part['domain'])
    end

    @hide_local.include?(part['custom_emoji_id'].to_i)
  end

  def hides_reaction?(reaction)
    return false if reaction.nil?

    custom_emoji = reaction.custom_emoji
    if custom_emoji&.domain.present?
      remote_included?(@hide_remote, custom_emoji.shortcode, custom_emoji.domain)
    elsif custom_emoji&.local?
      @hide_local.include?(custom_emoji.id)
    else
      @hide_unicode.include?(reaction.name)
    end
  end

  def hides_notification?(notification)
    return false unless notification&.type&.to_sym == :emoji_reaction

    hides_reaction?(notification.emoji_reaction)
  end

  def filter_notifications(relation)
    clause = notification_clause
    return relation if clause.nil?

    relation.where(Notification.sanitize_sql_array([clause.fetch(:sql), *clause.fetch(:binds)]))
  end

  def filter_reactions(relation)
    clause = reaction_clause
    return relation if clause.nil?

    relation.where(EmojiReaction.sanitize_sql_array([clause.fetch(:sql), *clause.fetch(:binds)]))
  end

  private

  def index!
    @hide_unicode = set_for(:hide_reactions, 'unicode', :native)
    @hide_local = set_for(:hide_reactions, 'local', :custom_emoji_id)
    @hide_remote = remote_set(:hide_reactions)
    @reject_unicode = set_for(:reject_reactions_to_own_posts, 'unicode', :native)
    @reject_local = set_for(:reject_reactions_to_own_posts, 'local', :custom_emoji_id)
    @reject_remote = remote_set(:reject_reactions_to_own_posts)
  end

  def set_for(effect, kind, reader)
    @rules.each_with_object({}) do |rule, memo|
      next unless rule.public_send(effect) && rule.kind == kind

      memo[rule.public_send(reader)] = true
    end
  end

  def remote_set(effect)
    @rules.each_with_object({}) do |rule, memo|
      next unless rule.public_send(effect) && rule.kind == 'remote'

      memo[[rule.shortcode, rule.domain]] = true
    end
  end

  def remote_included?(remote, shortcode, domain)
    normalized = EmojiMutes::Domain.normalize(domain)
    shortcode.present? && normalized.present? && remote[[shortcode, normalized]]
  end

  def notification_clause
    sql, binds = identity_sql('er', joined: true)
    return if sql.nil?

    {
      sql: <<~SQL.squish,
        NOT (
          notifications.type = 'emoji_reaction'
          AND notifications.activity_type = 'EmojiReaction'
          AND EXISTS (
            SELECT 1 FROM emoji_reactions er
            LEFT JOIN custom_emojis ce ON ce.id = er.custom_emoji_id
            WHERE er.id = notifications.activity_id AND (#{sql})
          )
        )
      SQL
      binds: binds,
    }
  end

  def reaction_clause
    pieces = []
    binds = []
    append_unicode(pieces, binds, 'emoji_reactions')
    append_local(pieces, binds, 'emoji_reactions')
    remote_sql, remote_binds = remote_exists_sql('emoji_reactions')
    if remote_sql
      pieces << remote_sql
      binds.concat(remote_binds)
    end
    return if pieces.empty?

    { sql: "NOT (#{pieces.join(' OR ')})", binds: binds }
  end

  def identity_sql(reaction_table, joined:)
    pieces = []
    binds = []
    append_unicode(pieces, binds, reaction_table)
    append_local(pieces, binds, reaction_table)
    append_remote(pieces, binds, joined)
    return if pieces.empty?

    [pieces.join(' OR '), binds]
  end

  def append_unicode(pieces, binds, table)
    names = @hide_unicode.keys
    return if names.empty?

    pieces << "(#{table}.custom_emoji_id IS NULL AND #{table}.name IN (?))"
    binds << names
  end

  def append_local(pieces, binds, table)
    ids = @hide_local.keys
    return if ids.empty?

    pieces << "(#{table}.custom_emoji_id IN (?))"
    binds << ids
  end

  def append_remote(pieces, binds, joined)
    return unless joined

    remote_pairs.each do |shortcode, domain|
      forms = EmojiMutes::Domain.forms(domain)
      next if forms.empty?

      pieces << '(ce.shortcode = ? AND ce.domain IN (?))'
      binds << shortcode
      binds << forms
    end
  end

  def remote_exists_sql(table)
    return if remote_pairs.empty?

    pieces = []
    binds = []
    remote_pairs.each do |shortcode, domain|
      forms = EmojiMutes::Domain.forms(domain)
      next if forms.empty?

      pieces << '(ce.shortcode = ? AND ce.domain IN (?))'
      binds << shortcode
      binds << forms
    end
    sql = <<~SQL.squish
      EXISTS (
        SELECT 1 FROM custom_emojis ce
        WHERE ce.id = #{table}.custom_emoji_id AND (#{pieces.join(' OR ')})
      )
    SQL
    [sql, binds]
  end

  def remote_pairs
    @hide_remote.keys
  end
end
