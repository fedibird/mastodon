# frozen_string_literal: true

module EmojiMutes
  # Viewer projection over the shared, unfiltered cache. Nothing here is
  # written back onto the Status or the cache. Groups and the display count
  # come from the same result, so serializer attribute order cannot mix
  # viewers. Anonymous calls apply no personal rule.
  class ReactionProjection
    class Result
      attr_reader :groups, :count

      def initialize(groups, count)
        @groups = groups
        @count = count
      end
    end

    class << self
      def for(status, account = nil, user: nil)
        new(status, account, user).to_result
      end

      def parse(cache)
        return [] if cache.blank?

        parsed = Oj.load(cache, mode: :strict)
        parsed.is_a?(Array) ? parsed : []
      rescue Oj::ParseError
        []
      end

      def unicode_only?(group)
        !group.key?('domain') && !group.key?('url') && !group.key?('static_url')
      end
    end

    def initialize(status, account, user = nil)
      @status = status
      @account = account
      @rules = RuleSet.for_user(user || account&.user)
    end

    def to_result
      groups = self.class.parse(@status.status_stat&.emoji_reactions_cache).map(&:dup)
      @blocked_domain_ids = blocked_domain_account_ids(groups)
      fill_parts!(groups) if @rules.hide_any?
      visible = groups.filter_map { |group| project_group(group) }
      Result.new(visible, visible.sum { |group| group['count'].to_i })
    end

    private

    # All groups on one status share the same domain blocks. Resolve their
    # account ids in one SQL query rather than one query per emoji group.
    def blocked_domain_account_ids(groups)
      return [] if @account.nil? || groups.empty?

      domains = @account.excluded_from_timeline_domains
      return [] if domains.blank?

      ids = groups.flat_map { |group| Array(group['account_ids']) }.uniq
      return [] if ids.empty?

      Account.where(id: ids, domain: domains).pluck(:id).map(&:to_s)
    end

    def fill_parts!(groups)
      return unless groups.any? { |group| !group['parts'].is_a?(Array) && !self.class.unicode_only?(group) }

      breakdown = IdentityBreakdown.for_status(@status.id)
      return if breakdown.blank?

      groups.each do |group|
        next if group['parts'].is_a?(Array)
        next if self.class.unicode_only?(group)

        group['parts'] = breakdown[group['name']] if breakdown[group['name']]
      end
    end

    def project_group(group)
      group['account_ids'] = Array(group['account_ids']).map(&:to_s)
      exclude = excluded_ids(group['account_ids'])
      group['account_ids'] -= exclude
      filter_parts!(group, exclude)
      hide!(group)
      group['count'] = group['account_ids'].size
      group['me'] = @account.present? && group['account_ids'].include?(@account.id.to_s)
      group['count'].positive? ? group : nil
    end

    def excluded_ids(account_ids)
      if @account.present?
        (@account.excluded_from_timeline_account_ids + (account_ids & @blocked_domain_ids) + (Account.excluded_silenced_account_ids - [@account.id])).uniq.map(&:to_s)
      else
        Account.excluded_silenced_account_ids.map(&:to_s)
      end
    end

    def filter_parts!(group, exclude)
      return unless group['parts'].is_a?(Array)

      group['parts'] = group['parts'].filter_map do |part|
        part = part.dup
        part['account_ids'] = Array(part['account_ids']).map(&:to_s) - exclude
        part['count'] = part['account_ids'].size
        part['count'].positive? ? part : nil
      end
    end

    def hide!(group)
      return unless @rules.hide_any?

      if group['parts'].is_a?(Array)
        original_representative = group['parts'].filter_map { |part| part['custom_emoji_id'] }.min_by(&:to_i)
        hidden_ids = []
        kept = []
        group['parts'].each do |part|
          if hide_part?(part)
            hidden_ids.concat(part['account_ids'])
          else
            kept << part
          end
        end
        group['account_ids'] -= hidden_ids
        group['parts'] = kept
        replace_representative!(group) if original_representative && kept.none? { |part| part['custom_emoji_id'] == original_representative }
      elsif self.class.unicode_only?(group) && @rules.hides_unicode_name?(group['name'])
        group['account_ids'] = []
      end
    end

    def hide_part?(part)
      @rules.hides_identity?(part['identity'])
    end

    def replace_representative!(group)
      chosen = group['parts'].select { |part| part['custom_emoji_id'] }.min_by { |part| part['custom_emoji_id'].to_i }
      if chosen.nil?
        %w(url static_url domain width height alternate_name ruby).each { |key| group.delete(key) }
        return
      end

      %w(url static_url domain width height alternate_name ruby).each do |key|
        if chosen.key?(key)
          group[key] = chosen[key]
        else
          group.delete(key)
        end
      end
    end
  end
end
