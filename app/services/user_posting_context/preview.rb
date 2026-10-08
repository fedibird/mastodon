# frozen_string_literal: true

class UserPostingContext
  # Merges the user's usual settings, this style's overrides, and a group
  # destination's current discovery result. This does not publish a post and
  # does not fetch a remote account.
  #
  # permission == 'permitted' is the only state that means the destination
  # allowed the value. unsupported, unknown, and a missing constraint list
  # are never reported as permitted.
  class Preview
    Field = Struct.new(:source, :value, :usual_value, :permission, :allowed, :detail, keyword_init: true) do
      def permitted?
        permission == 'permitted'
      end

      def inherited?
        source == 'inherit'
      end
    end

    Result = Struct.new(
      :destination, :discovery_status, :discovery_reason, :discovery_trust,
      :visibility, :language, :sensitive, :spoiler,
      :user_hashtags, :required_rules, :recommended_rules, :conflicts,
      keyword_init: true
    )

    def self.build(user:, context:)
      new(user, context).build
    end

    def initialize(user, context)
      @user = user
      @context = context
      @defaults = stringify_hash(context.defaults)
      @managed = stringify_hash(context.managed)
      @discovery = load_discovery
    end

    def build
      visibility = visibility_field
      language = language_field
      sensitive = sensitive_field
      spoiler = spoiler_field

      Result.new(
        destination: destination,
        discovery_status: discovery_status,
        discovery_reason: discovery_reason,
        discovery_trust: discovery_trust,
        visibility: visibility,
        language: language,
        sensitive: sensitive,
        spoiler: spoiler,
        user_hashtags: user_hashtags,
        required_rules: required_rules,
        recommended_rules: recommended_rules,
        conflicts: conflicts_for(visibility, language)
      )
    end

    private

    def load_discovery
      case @context.target_kind
      when 'group'
        discover_group
      when 'hashtag'
        { 'status' => 'not_applicable', 'reason' => 'hashtag_target', 'context' => nil }
      when 'none'
        { 'status' => 'not_applicable', 'reason' => 'no_target', 'context' => nil }
      else
        { 'status' => 'unknown', 'reason' => 'target_kind', 'context' => nil }
      end
    end

    def discover_group
      account = @context.target_account
      return { 'status' => 'unknown', 'reason' => 'missing_group', 'context' => nil } if account.nil?

      stringify(PostingContext::DiscoveryService.new.call(account, viewer: @user.account))
    end

    def destination
      {
        'kind' => @context.target_kind,
        'hashtag' => @context.target_hashtag,
        'account_id' => @context.target_account_id&.to_s,
        'acct' => @context.target_account&.acct,
      }
    end

    def visibility_field
      explicit = @defaults.key?('visibility')
      usual = @user.setting_default_privacy
      value = explicit ? @defaults['visibility'] : usual
      allowed = allowed_visibilities
      Field.new(
        source: explicit ? 'explicit' : 'inherit',
        value: value,
        usual_value: usual,
        permission: list_permission(allowed, value),
        allowed: allowed.is_a?(Array) ? allowed : [],
        detail: nil
      )
    end

    def language_field
      language = @defaults['language']
      usual = @user.setting_default_language
      if !@defaults.key?('language')
        source = 'inherit'
        value = usual
      elsif language.is_a?(Hash) && language['mode'] == 'auto'
        source = 'clear'
        value = nil
      else
        source = 'explicit'
        value = language.is_a?(Hash) ? language['code'] : nil
      end

      Field.new(
        source: source,
        value: value,
        usual_value: usual,
        permission: list_permission(allowed_languages, value),
        allowed: allowed_languages.is_a?(Array) ? allowed_languages : [],
        detail: nil
      )
    end

    def sensitive_field
      explicit = @defaults.key?('sensitive')
      usual = @user.setting_default_sensitive == true
      Field.new(
        source: explicit ? 'explicit' : 'inherit',
        value: explicit ? @defaults['sensitive'] : usual,
        usual_value: usual,
        permission: undeclared_or_unverified,
        allowed: [],
        detail: nil
      )
    end

    def spoiler_field
      spoiler = @defaults['spoiler']
      if !@defaults.key?('spoiler')
        source = 'inherit'
        value = { 'enabled' => false, 'text' => '' }
      elsif spoiler.is_a?(Hash) && spoiler['enabled'] == false
        source = 'clear'
        value = { 'enabled' => false, 'text' => '' }
      else
        source = 'explicit'
        value = { 'enabled' => true, 'text' => spoiler.is_a?(Hash) ? spoiler['text'].to_s : '' }
      end

      Field.new(
        source: source,
        value: value,
        usual_value: { 'enabled' => false, 'text' => '' },
        permission: undeclared_or_unverified,
        allowed: [],
        detail: nil
      )
    end

    def list_permission(allowed, value)
      return 'unverified' if discovery_trust == 'unverified' || allowed == :invalid
      return 'not_applicable' if discovery_trust == 'not_applicable'
      return 'undeclared' unless allowed.is_a?(Array)

      allowed.include?(value.to_s) ? 'permitted' : 'conflict'
    end

    def undeclared_or_unverified
      case discovery_trust
      when 'unverified'
        'unverified'
      when 'not_applicable'
        'not_applicable'
      else
        'undeclared'
      end
    end

    def allowed_visibilities
      declared_string_list('allowed_visibilities')
    end

    def allowed_languages
      declared_string_list('allowed_languages')
    end

    def declared_string_list(key)
      return nil unless discovery_trust == 'resolved'

      list = context_hash.dig('constraints', key)
      return nil if list.nil?
      return :invalid unless list.is_a?(Array) && list.all? { |item| item.is_a?(String) }

      list
    end

    def user_hashtags
      Array(@managed['hashtags']).select { |tag| tag.is_a?(Hash) && tag['enforcement'] == 'advisory' }
    end

    def required_rules
      return [] unless discovery_trust == 'resolved'

      rules = []
      collect(context_hash.dig('managed', 'hashtags'), 'required').each do |tag|
        rules << rule('hashtag', tag['name'], tag['rule_id'])
      end
      collect(context_hash.dig('managed', 'mentions'), 'required').each do |mention|
        rules << rule('mention', mention['acct'], mention['rule_id'])
      end
      collect(context_hash.dig('requirements', 'following_accounts'), 'required').each do |account|
        rules << rule('following', account['acct'], account['rule_id'])
      end
      audience = context_hash.dig('protocol', 'activitypub', 'audience')
      rules << rule('audience', audience['acct'], audience['rule_id']) if audience.is_a?(Hash) && audience['enforcement'] == 'required'
      rules
    end

    def recommended_rules
      return [] unless discovery_trust == 'resolved'

      rules = []
      recommended = context_hash['recommended']
      if recommended.is_a?(Hash)
        recommended.each { |key, value| rules << rule('value', "#{key}: #{value}", nil) }
      end
      %w(hashtags mentions).each do |key|
        collect(context_hash.dig('managed', key), 'recommended').each do |item|
          rules << rule(key, item['name'] || item['acct'], item['rule_id'])
        end
      end
      rules
    end

    def conflicts_for(visibility, language)
      items = []
      [visibility, language].each do |field|
        next unless %w(conflict unverified).include?(field.permission)

        items << {
          'field' => field.equal?(visibility) ? 'visibility' : 'language',
          'kind' => field.permission,
          'value' => field.value,
          'allowed' => field.allowed,
        }
      end
      items << { 'field' => 'discovery', 'kind' => 'unverified', 'value' => nil, 'allowed' => [] } if discovery_trust == 'unverified' && items.empty?
      items
    end

    def collect(list, enforcement)
      Array(list).select { |item| item.is_a?(Hash) && item['enforcement'] == enforcement }
    end

    def rule(kind, label, rule_id)
      { 'kind' => kind, 'label' => label.to_s, 'rule_id' => rule_id.to_s }
    end

    def discovery_status
      @discovery['status'].to_s
    end

    def discovery_reason
      @discovery['reason'].to_s
    end

    def discovery_trust
      return 'not_applicable' if %w(none hashtag).include?(@context.target_kind)
      return 'resolved' if discovery_status == 'resolved' && context_hash.is_a?(Hash) && !context_hash.empty?
      return 'not_applicable' if discovery_status == 'not_applicable'

      'unverified'
    end

    def context_hash
      value = @discovery['context']
      value.is_a?(Hash) ? value : {}
    end

    def stringify_hash(value)
      value.is_a?(Hash) ? stringify(value) : {}
    end

    def stringify(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), memo| memo[key.to_s] = stringify(item) }
      when Array
        value.map { |item| stringify(item) }
      else
        value
      end
    end
  end
end
