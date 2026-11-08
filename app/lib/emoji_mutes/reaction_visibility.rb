# frozen_string_literal: true

module EmojiMutes
  # SQL exclusion applied before LIMIT so a page of only hidden rows cannot
  # swallow the following page or disagree with the unread count. Rules are
  # the viewer's and were loaded once for the request.
  module ReactionVisibility
    module_function

    def exclude_reactions(scope, user)
      rules = RuleSet.for_user(user)
      clause = reaction_clause(rules)
      return scope if clause.nil?

      scope.where(clause)
    end

    def exclude_notifications(scope, user)
      rules = RuleSet.for_user(user)
      clause = reaction_clause(rules, notifications: true)
      return scope if clause.nil?

      scope.where(clause)
    end

    def hidden_notification?(notification, user)
      return false unless notification&.type == :emoji_reaction

      reaction = notification.activity if notification.activity.is_a?(EmojiReaction)
      reaction ||= notification.emoji_reaction
      return false if reaction.nil?

      RuleSet.for_user(user).hides_identity?(Identity.for_reaction(reaction))
    end

    def reaction_clause(rules, notifications: false)
      return nil unless rules.hide_any?

      pieces = []
      variants = rules.hide_unicode_variants
      if variants.any?
        quoted = variants.map { |name| quote(name) }.join(', ')
        pieces << "(emoji_reactions.custom_emoji_id IS NULL AND emoji_reactions.name IN (#{quoted}))"
      end

      ids = rules.hide_local_ids
      pieces << "emoji_reactions.custom_emoji_id IN (#{ids.join(', ')})" if ids.any?

      pairs = rules.hide_remote_pairs
      if pairs.any?
        tuple = pairs.map { |domain, shortcode| "(#{quote(domain)}, #{quote(shortcode)})" }.join(', ')
        pieces << <<~SQL.squish
          EXISTS (
            SELECT 1 FROM custom_emojis
            WHERE custom_emojis.id = emoji_reactions.custom_emoji_id
              AND (custom_emojis.domain, custom_emojis.shortcode) IN (#{tuple})
          )
        SQL
      end
      return nil if pieces.empty?

      match = pieces.join(' OR ')
      if notifications
        Arel.sql(<<~SQL.squish)
          NOT EXISTS (
            SELECT 1 FROM emoji_reactions
            WHERE emoji_reactions.id = notifications.activity_id
              AND notifications.type = 'emoji_reaction'
              AND (#{match})
          )
        SQL
      else
        Arel.sql("NOT (#{match})")
      end
    end

    def quote(value)
      ActiveRecord::Base.connection.quote(value)
    end
  end
end
