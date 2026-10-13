# frozen_string_literal: true

require 'set'
require_relative 'extract'

module SettingsServiceCatalog
  class Build
    PROFILE_VARS = %w[noindex hide_network hide_statuses_count hide_following_count hide_followers_count enable_reaction].freeze
    HIGH_RISK_VARS = %w[
      disable_post disable_reactions disable_follow disable_unfollow disable_block
      disable_domain_block disable_report disable_clear_all_notifications disable_account_delete
      prohibited_visibilities prohibited_words unlocked_for_official_app
      noindex hide_network hide_statuses_count hide_following_count hide_followers_count enable_reaction
      hide_direct_from_timeline hide_personal_from_timeline hide_personal_from_account
    ].freeze
    NUMERIC_STRINGS = %w[
      content_font_size info_font_size composer_font_size composer_min_height
      content_emoji_reaction_size emoji_scale picker_emoji_size max_frequently_used_emojis
    ].freeze
    POSTING = %w[
      default_privacy default_sensitive default_language default_expires_in default_expires_action
      show_application prohibited_visibilities prohibited_words disable_post
      match_visibility_of_references enable_status_reference default_search_searchability
    ].freeze
    LEGACY_FORM_KEYS = %w(
      default_privacy default_sensitive default_language show_translation_bar
      translation_preferred_mode new_features_policy content_font_size info_font_size
      reduce_motion
    ).freeze
    TRANSLATION = %w[show_translation_bar translation_preferred_mode].freeze
    PRIVACY = %w[
      noindex hide_network hide_statuses_count hide_following_count hide_followers_count
      hide_statuses_count_from_yourself hide_following_count_from_yourself hide_followers_count_from_yourself
      hide_subscribing_count_from_yourself hide_following_from_yourself hide_followers_from_yourself
      hide_joined_date_from_yourself hide_direct_from_timeline hide_personal_from_timeline
      hide_personal_from_account hide_privacy_meta
    ].freeze

    def initialize(root)
      @root = root
      @facts = Extract.new(root).call
    end

    def document
      entries = user_entries + nested_entries + column_entries + account_entries + site_entries + client_entries + derived_entries + exclusion_entries
      {
        'meta' => meta(entries),
        'entries' => entries,
        'open_questions' => open_questions,
        'extractor_limits' => extractor_limits,
      }
    end

    private

    def meta(entries)
      by_disposition = entries.group_by { |entry| entry.fetch('disposition') }.transform_values(&:size).sort.to_h
      by_audit = entries.group_by { |entry| entry.fetch('audit_status') }.transform_values(&:size).sort.to_h
      by_owner = entries.group_by { |entry| entry.fetch('owner') }.transform_values(&:size).sort.to_h
      {
        'catalog_version' => 1,
        'kind' => 'audit_inventory',
        'not_runtime_contract' => true,
        'base_commit' => '90ba4b16e175ff6fe413b94db218deefa83f6777',
        'purpose' => 'P1-0 audit catalog for a future Settings Service reader and schema. Not loaded by production.',
        'stats' => {
          'entries' => entries.size,
          'by_disposition' => by_disposition,
          'by_audit_status' => by_audit,
          'by_owner' => by_owner,
          'open_questions' => open_questions.size,
          'form_inputs' => form_input_stats,
        },
      }
    end

    def form_input_stats
      @facts[:forms].transform_values do |fields|
        {
          'active' => fields.count { |field| !field['commented'] },
          'commented' => fields.count { |field| field['commented'] },
          'conditional' => fields.count { |field| field['conditional'] },
        }
      end
    end

    def yaml_by_key
      @yaml_by_key ||= @facts[:yaml].to_h { |row| [row['key'], row] }
    end

    def user_vars
      @user_vars ||= begin
        vars = @facts[:decorator]['boolean'] + @facts[:decorator]['string'] + @facts[:decorator]['integer']
        vars += @facts[:delegate]['keys']
        vars += @facts[:permit]['scalars']
        vars += @facts[:initial_state]['setting_refs'].map { |ref| ref['var'] }
        vars += form_setting_names
        vars.uniq.sort
      end
    end

    def form_setting_names
      @facts[:forms].each_value.flat_map do |fields|
        fields.filter_map { |field| field['name'].delete_prefix('setting_') if field['nested'].nil? && field['name'].start_with?('setting_') }
      end
    end

    def user_entries
      user_vars.map { |var| user_entry(var) }
    end

    def user_entry(var)
      yaml = yaml_by_key[var]
      forms = form_hits(var)
      decorator_group = decorator_group_for(var)
      initial = @facts[:initial_state]['setting_refs'].select { |ref| ref['var'] == var }
      js = js_for_meta(var)
      css = @facts[:css_vars]['vars'].include?(var)
      html = @facts[:html_classes]['vars'].select { |row| row['var'] == var }
      special = special_case(var)
      entry = {
        'key' => "user.#{var}",
        'category' => category_for(var),
        'owner' => 'user',
        'disposition' => disposition_for(var, forms),
        'storage' => "settings(thing_type=User,thing_id=users.id,var=#{var}) YAML text; default from config/settings.yml via ScopedSettings, except theme and noindex which fall back to the unscoped Setting row",
        'legacy_keys' => legacy_keys(var, forms, initial),
        'raw_type' => raw_type_for(var, yaml, decorator_group),
        'effective_type' => effective_type_for(var, yaml, decorator_group),
        'default_source' => default_source_for(var, yaml),
        'read_sources' => read_sources_for(var, initial, js, css, html),
        'write_sources' => write_sources_for(var, forms),
        'normalization' => normalization_for(var, decorator_group),
        'availability' => availability_for(var, forms),
        'read_policy' => read_policy_for(var),
        'write_policy' => write_policy_for(var, forms),
        'side_effects' => side_effects_for(var, css, html),
        'apply_hint' => apply_hint_for(var, js, css, html, initial),
        'client_reference' => client_reference_for(var, js, css, html, initial),
        'configured_vs_effective' => configured_vs_effective_for(var, initial),
        'form_status' => form_status(forms),
        'source_refs' => source_refs_for(var, yaml, forms, initial, js, css, html, decorator_group),
        'audit_status' => 'verified',
        'notes' => notes_for(var, yaml, forms, decorator_group, initial, js),
      }
      special&.each { |key, value| entry[key] = value }
      entry['audit_status'] = audit_status_for(entry, var)
      entry
    end

    def nested_entries
      groups = {}
      %w[notification_emails interactions].each do |group|
        yaml_keys = yaml_by_key[group] && yaml_by_key[group]['value'].is_a?(Hash) ? yaml_by_key[group]['value'].keys : []
        permit_keys = @facts[:permit]['nested'][group] || []
        form_keys = @facts[:forms]['notifications'].select { |field| field['nested'] == group }.map { |field| field['name'] }
        (yaml_keys + permit_keys + form_keys).uniq.sort.each do |child|
          groups["#{group}.#{child}"] = [group, child]
        end
      end
      groups.values.map { |group, child| nested_entry(group, child) }
    end

    def nested_entry(group, child)
      yaml_hash = yaml_by_key[group]['value']
      yaml_value = yaml_hash.is_a?(Hash) ? yaml_hash[child] : nil
      in_yaml = yaml_hash.is_a?(Hash) && yaml_hash.key?(child)
      in_permit = (@facts[:permit]['nested'][group] || []).include?(child)
      forms = @facts[:forms]['notifications'].select { |field| field['nested'] == group && field['name'] == child }
      mismatch = !in_yaml || !in_permit || forms.empty? || forms.any? { |field| field['commented'] }
      {
        'key' => "user.#{group}.#{child}",
        'category' => group == 'notification_emails' ? 'notifications' : 'safety',
        'owner' => 'user',
        'disposition' => nested_disposition(group, in_yaml, forms),
        'storage' => "settings var #{group} as a YAML hash merged over the config/settings.yml default hash on read; ScopedSettings#[] returns inside Rails.cache.fetch for hashes, so this read path does not populate cache",
        'legacy_keys' => {
          'settings_var' => group,
          'hash_key' => child,
          'form' => forms.empty? ? nil : "user[#{group}][#{child}]",
          'permit' => in_permit ? child : nil,
          'getter' => "user.settings.#{group}['#{child}']",
        }.compact,
        'raw_type' => in_yaml ? 'boolean' : 'absent_from_yaml',
        'effective_type' => 'boolean',
        'default_source' => in_yaml ? "config/settings.yml defaults.#{group}.#{child}=#{yaml_value.inspect}; missing keys are filled from that hash on read" : "no config/settings.yml key #{group}.#{child}; a saved hash keeps only submitted keys after merge",
        'read_sources' => ["rails.preferences.notifications form via settings.#{group}", 'NotifyService reads the stored hash on each notification'],
        'write_sources' => write_sources_nested(in_permit, forms),
        'normalization' => 'UserSettingsDecorator merges only submitted keys and casts each value with ActiveModel::Type::Boolean. Omitted keys stay at the previously stored value. Unchecked Simple Form booleans submit 0.',
        'availability' => nested_availability(group, child, forms),
        'read_policy' => 'general',
        'write_policy' => nested_write_policy(group, in_yaml, forms),
        'side_effects' => group == 'notification_emails' ? ['email_delivery', 'settings_cache_write_skipped_for_hash_read'] : ['notification_and_delivery_filter', 'settings_cache_write_skipped_for_hash_read'],
        'apply_hint' => 'live',
        'client_reference' => ['none'],
        'configured_vs_effective' => 'same_when_key_present_else_yaml_default',
        'form_status' => form_status(forms),
        'source_refs' => nested_refs(group, child, forms),
        'audit_status' => mismatch ? 'unresolved' : 'verified',
        'notes' => nested_notes(group, child, in_yaml, in_permit, forms, yaml_value),
      }
    end

    def column_entries
      [
        column_entry('locale', 'user.locale', 'users.locale string; validated against I18n.available_locales and cleared when unknown', 'string', 'appearance', 'InitialState meta.locale is I18n.locale at render, which preferences#update sets from the saved user locale. It is not user.settings.'),
        column_entry('time_zone', 'user.time_zone', 'users.time_zone string; cleared when ActiveSupport::TimeZone does not know it. The form falls back to Time.zone for display when the column is nil.', 'string', 'appearance', 'Not part of User.settings and not present in InitialState.'),
        column_entry('chosen_languages', 'user.chosen_languages', 'users.chosen_languages string array. Blank values are removed and an empty array becomes nil.', 'array', 'other', 'Public-timeline language filter stored on users, not in settings. The other preferences form saves it through user_params.'),
      ]
    end

    def column_entry(column, key, storage, type, form, note)
      {
        'key' => key,
        'category' => column == 'chosen_languages' ? 'timelines' : 'appearance',
        'owner' => 'user',
        'disposition' => 'user_column',
        'storage' => storage,
        'legacy_keys' => { 'column' => column, 'form' => column, 'permit' => column },
        'raw_type' => type,
        'effective_type' => type,
        'default_source' => 'database column default null; no settings.yml entry',
        'read_sources' => ["rails.preferences.#{form}"],
        'write_sources' => ["rails.preferences.#{form} via User#update"],
        'normalization' => column == 'locale' ? 'sanitize_locale' : (column == 'time_zone' ? 'sanitize_time_zone' : 'sanitize_languages'),
        'availability' => 'always',
        'read_policy' => 'general',
        'write_policy' => 'general',
        'side_effects' => column == 'locale' ? ['sets I18n.locale for the redirect after preferences save'] : ['none'],
        'apply_hint' => 'reload',
        'client_reference' => column == 'locale' ? ['initial_state_meta_locale_is_request_locale'] : ['none'],
        'configured_vs_effective' => 'distinct_from_user_settings',
        'form_status' => 'active',
        'source_refs' => column_refs(column),
        'audit_status' => 'verified',
        'notes' => note,
      }
    end

    def account_entries
      profile = @facts[:forms]['profile']
      profile.map do |field|
        storage = account_storage(field['nested'] || field['name'])
        key = field['nested'] ? "account.#{field['nested']}.#{field['name']}" : "account.#{field['name']}"
        {
          'key' => key,
          'category' => 'profile',
          'owner' => field['name'] == 'searchability' ? 'account' : 'account',
          'disposition' => 'excluded',
          'storage' => storage,
          'legacy_keys' => { 'form' => field['name'], 'permit' => field['name'], 'credentials' => credentials_account_param?(field['name']) ? field['name'] : nil }.compact,
          'raw_type' => field['name'] == 'searchability' ? 'enum integer' : (field['widget'] == 'boolean' ? 'boolean' : 'see storage'),
          'effective_type' => field['name'] == 'searchability' ? 'string enum name' : 'see storage',
          'default_source' => field['name'] == 'searchability' ? "accounts.searchability database default direct (0). This is not user.setting_default_search_searchability." : 'account column or accounts.settings JSON; not config/settings.yml',
          'read_sources' => ['rails.profiles', 'REST::CredentialAccountSerializer and REST::AccountSerializer where the attribute is public'],
          'write_sources' => ['rails.profiles via UpdateAccountService', credentials_account_param?(field['name']) ? 'api.v1.accounts.credentials update' : nil].compact,
          'normalization' => 'UpdateAccountService / AccountSettings. Not UserSettingsDecorator.',
          'availability' => field['conditional'] ? "conditional: #{field['condition']}" : 'profile form',
          'read_policy' => 'exclude',
          'write_policy' => 'exclude',
          'side_effects' => ['activitypub_update_distribution on successful profile save', field['name'] == 'locked' ? 'user.setting_default_privacy effective value depends on account.locked when default_privacy is unset' : nil, field['name'] == 'searchability' ? 'InitialState compose.default_searchability reads this column, not the user setting' : nil].compact,
          'apply_hint' => 'reload',
          'client_reference' => field['name'] == 'searchability' ? ['redux_compose_default_searchability'] : ['account_serializer'],
          'configured_vs_effective' => 'not_a_user_setting',
          'form_status' => field['commented'] ? 'commented' : (field['conditional'] ? 'conditional' : 'active'),
          'source_refs' => ["#{field['path']}:#{field['line']}", 'app/controllers/settings/profiles_controller.rb:23'],
          'audit_status' => 'verified',
          'notes' => account_note(field['name']),
        }
      end
    end

    def site_entries
      admin = admin_keys
      consumed = user_vars + %w[notification_emails interactions]
      yaml_by_key.keys.reject { |key| consumed.include?(key) }.sort.map do |key|
        row = yaml_by_key[key]
        readers = site_reader_files(key)
        admin_key = admin.include?(key) || readers.any? { |path| path.include?('admin') || path.include?('action_review') }
        {
          'key' => "site.#{key}",
          'category' => 'site',
          'owner' => 'site',
          'disposition' => readers.empty? && !admin_key ? 'retained_inactive' : 'site',
          'storage' => "unscoped settings row var=#{key}, default config/settings.yml. The same defaults hash is also the ScopedSettings fallback, so user.settings.#{key} would return this default if called.",
          'legacy_keys' => { 'settings_var' => key, 'admin_form' => admin.include?(key) ? key : nil, 'readers' => readers }.compact,
          'raw_type' => row['yaml_type'],
          'effective_type' => row['yaml_type'],
          'default_source' => "config/settings.yml defaults.#{key}",
          'read_sources' => readers.empty? ? ['no Setting.key or Setting["key"] reader found under app/'] : readers,
          'write_sources' => if admin.include?(key)
                               ['admin.settings Form::AdminSettings']
                             elsif readers.any? { |path| path.include?('action_review_settings') }
                               ['admin action review settings form']
                             else
                               ['no admin form in Form::AdminSettings::KEYS']
                             end,
          'normalization' => 'RailsSettings YAML column. Hash defaults are merged on unscoped read the same way as scoped reads.',
          'availability' => 'instance',
          'read_policy' => 'admin',
          'write_policy' => admin_key ? 'admin' : 'not_writable',
          'side_effects' => ['unscoped settings cache'],
          'apply_hint' => readers.empty? ? 'unknown' : 'live',
          'client_reference' => ['none'],
          'configured_vs_effective' => 'site_default_shared_with_scoped_fallback',
          'form_status' => 'absent',
          'source_refs' => ["config/settings.yml:#{row['line']}", admin.include?(key) ? 'app/models/form/admin_settings.rb:6' : nil].compact,
          'audit_status' => readers.empty? && !admin.include?(key) ? 'inferred' : 'verified',
          'notes' => site_note(key, admin.include?(key), readers),
        }
      end
    end

    def client_entries
      container = {
        'key' => 'client.web_settings',
        'category' => 'client',
        'owner' => 'client',
        'disposition' => 'client',
        'storage' => 'web_settings.data JSON, one row per user. The server accepts params[:data] with no schema.',
        'legacy_keys' => {
          'rails_route' => 'PUT and PATCH /api/web/settings',
          'webui_method' => 'PUT',
          'redux' => 'state.settings',
          'initial_state' => 'settings',
        },
        'raw_type' => 'json',
        'effective_type' => 'immutable map in Redux',
        'default_source' => 'app/javascript/mastodon/reducers/settings.js initialState, merged over the saved JSON on STORE_HYDRATE',
        'read_sources' => ['InitialState settings, which is the Web::Setting JSON merged over four about-page site flags'],
        'write_sources' => ['PUT /api/web/settings from app/javascript/mastodon/actions/settings.js. Rails resource :settings update also accepts PATCH on the same action. Session and CSRF.'],
        'normalization' => 'No server normalization. A request spec shows a JSON boolean arriving as the string true. The saved flag is stripped before PUT.',
        'availability' => 'signed-in WebUI session',
        'read_policy' => 'exclude',
        'write_policy' => 'session_web',
        'side_effects' => ['redux live update', 'no User.settings write'],
        'apply_hint' => 'live',
        'client_reference' => ['redux_settings'],
        'configured_vs_effective' => 'client_owned',
        'form_status' => 'absent',
        'source_refs' => [
          'app/controllers/api/web/settings_controller.rb:7',
          "app/javascript/mastodon/actions/settings.js:#{read_line('app/javascript/mastodon/actions/settings.js', "api().put('/api/web/settings'")}",
          "config/routes.rb:#{read_line('config/routes.rb', 'resource :settings, only: [:update]')}",
          'app/helpers/application_helper.rb:207',
          'app/javascript/mastodon/reducers/settings.js:12',
        ],
        'audit_status' => 'verified',
        'notes' => 'D3 keeps Web::Setting. InitialState key settings is this blob, not User.settings. The WebUI sends PUT. The Rails update route accepts PUT and PATCH and does not change behavior between them. Completeness of the Redux leaf schema is not claimed; the server schema is open. Group keys below are the top-level keys of the reducer initialState.',
      }
      groups = @facts[:reducer_groups].map do |group|
        {
          'key' => "client.web_settings.#{group['key']}",
          'category' => 'client',
          'owner' => 'client',
          'disposition' => 'client',
          'storage' => 'web_settings.data JSON',
          'legacy_keys' => { 'redux' => group['key'] },
          'raw_type' => 'json',
          'effective_type' => 'redux value',
          'default_source' => "reducers/settings.js initialState.#{group['key']}",
          'read_sources' => ['redux settings after STORE_HYDRATE'],
          'write_sources' => ['PUT /api/web/settings from the WebUI; the Rails update route also accepts PATCH'],
          'normalization' => 'client-defined',
          'availability' => 'signed-in WebUI',
          'read_policy' => 'exclude',
          'write_policy' => 'session_web',
          'side_effects' => group['key'] == 'saved' ? ['transient; filtered out before save'] : ['redux live update'],
          'apply_hint' => 'live',
          'client_reference' => ['redux_settings'],
          'configured_vs_effective' => 'client_owned',
          'form_status' => 'absent',
          'source_refs' => ["app/javascript/mastodon/reducers/settings.js:#{group['line']}"],
          'audit_status' => 'inferred',
          'notes' => 'Top-level Redux settings key. Nested leaves are not expanded. portableComposerDisplayMode is temporary per-composer UI state in this blob, not translation_preferred_mode. audit_status is inferred because the reducer shape was read statically and the saved JSON may contain additional keys.',
        }
      end
      [container] + groups
    end

    def derived_entries
      [
        {
          'key' => 'derived.preferred_posting_language',
          'category' => 'posting',
          'owner' => 'user',
          'disposition' => 'derived',
          'storage' => 'not stored; User#preferred_posting_language cascades setting_default_language, users.locale, then I18n.locale through valid_locale_or_nil',
          'legacy_keys' => { 'getter' => 'preferred_posting_language', 'preferences_api' => 'posting:default:language', 'initial_state' => 'compose.default_language' },
          'raw_type' => 'none',
          'effective_type' => 'string locale or nil',
          'default_source' => 'valid_locale_cascade(setting_default_language, locale, I18n.locale)',
          'read_sources' => ['preferences API posting:default:language', 'InitialState compose.default_language'],
          'write_sources' => ['none; write default_language or users.locale instead'],
          'normalization' => 'strips region (ja-JP -> ja) and skips invalid locales',
          'availability' => 'always',
          'read_policy' => 'general',
          'write_policy' => 'not_writable',
          'side_effects' => ['none'],
          'apply_hint' => 'reinitialize',
          'client_reference' => ['redux_compose_default_language'],
          'configured_vs_effective' => 'distinct',
          'form_status' => 'absent',
          'source_refs' => ["app/models/user.rb:#{read_line('app/models/user.rb', 'def preferred_posting_language')}", 'app/helpers/languages_helper.rb:266', 'app/serializers/rest/preferences_serializer.rb:20', 'app/serializers/rest/credential_account_serializer.rb:18', "app/serializers/initial_state_serializer.rb:#{read_line('app/serializers/initial_state_serializer.rb', "preference_effective('preferred_posting_language')")}"],
          'audit_status' => 'verified',
          'notes' => 'Preferences API and InitialState compose use this cascade. Credentials source.language and the Rails form use setting_default_language, the raw stored value, which can be nil. Those three are not synonyms.',
        },
        {
          'key' => 'derived.preferences.reading_autoplay_gifs',
          'category' => 'appearance',
          'owner' => 'user',
          'disposition' => 'derived',
          'storage' => 'not stored; AND of auto_play_avatar, auto_play_emoji, auto_play_header, and auto_play_media',
          'legacy_keys' => { 'preferences_api' => 'reading:autoplay:gifs' },
          'raw_type' => 'none',
          'effective_type' => 'boolean',
          'default_source' => 'conjunction of the four user settings',
          'read_sources' => ['GET /api/v1/preferences'],
          'write_sources' => ['none'],
          'normalization' => 'boolean conjunction',
          'availability' => 'oauth read or read:accounts',
          'read_policy' => 'general',
          'write_policy' => 'not_writable',
          'side_effects' => ['none'],
          'apply_hint' => 'unknown',
          'client_reference' => ['preferences_api_only'],
          'configured_vs_effective' => 'distinct',
          'form_status' => 'absent',
          'source_refs' => ['app/serializers/rest/preferences_serializer.rb:32', 'app/controllers/api/v1/preferences_controller.rb:4'],
          'audit_status' => 'verified',
          'notes' => 'Mastodon-compatible aggregate. Fedibird stores and displays the four autoplay flags separately. A true result means all four are true.',
        },
        {
          'key' => 'derived.translation_private_content_allowed',
          'category' => 'translation',
          'owner' => 'user',
          'disposition' => 'derived',
          'storage' => 'not a user setting; TranslationService.private_content_allowed_for(user) asks the user translation backend',
          'legacy_keys' => { 'initial_state' => 'meta.translation_private_content_allowed', 'js' => 'translationPrivateContentAllowed' },
          'raw_type' => 'none',
          'effective_type' => 'boolean',
          'default_source' => 'false when the backend is missing, ambiguous, or does not allow private content',
          'read_sources' => ['InitialState meta'],
          'write_sources' => ['none'],
          'normalization' => 'rescue NotConfiguredError and AmbiguousPersonalProvider to false',
          'availability' => 'depends on the configured translation backend',
          'read_policy' => 'exclude',
          'write_policy' => 'not_writable',
          'side_effects' => ['none'],
          'apply_hint' => 'reinitialize',
          'client_reference' => ['static_import'],
          'configured_vs_effective' => 'derived',
          'form_status' => 'absent',
          'source_refs' => ['app/lib/translation_service.rb:70', 'app/serializers/initial_state_serializer.rb:96', 'app/javascript/mastodon/initial_state.js:17'],
          'audit_status' => 'verified',
          'notes' => 'Capability flag, not a preference. Personal DeepL versus the instance backend can change it. Do not catalog it as translation_preferred_mode.',
        },
      ]
    end

    def exclusion_entries
      [
        exclusion('excluded.oauth_applications', 'OAuth application management under settings/applications. Authorization records, not preferences.', 'app/controllers/settings/applications_controller.rb'),
        exclusion('excluded.two_factor', 'TOTP, WebAuthn, and recovery codes. Credentials, not preferences.', 'app/controllers/settings/two_factor_authentication_methods_controller.rb'),
        exclusion('excluded.sessions_and_login_activity', 'Session and login-activity management.', 'app/controllers/settings/sessions_controller.rb'),
        exclusion('excluded.imports_exports', 'Account import and export jobs.', 'app/controllers/settings/imports_controller.rb'),
        exclusion('excluded.migration_and_aliases', 'Account move and alias records.', 'app/controllers/settings/migrations_controller.rb'),
        exclusion('excluded.deletion', 'Account deletion is gated by disable_account_delete but the flow is not a preference value.', 'app/controllers/settings/deletes_controller.rb'),
        exclusion('excluded.external_credentials', 'DeepL and other external service credentials. Secrets, excluded from a preferences schema.', 'app/controllers/settings/external_services_controller.rb'),
        exclusion('excluded.subscribes', 'Keyword, account, and domain subscription resources. Not User.settings.', 'app/controllers/settings/keyword_subscribes_controller.rb'),
        exclusion('excluded.follow_tags_and_featured_tags', 'Followed tags, featured tags, and favourite tags.', 'app/controllers/settings/follow_tags_controller.rb'),
        exclusion('excluded.posting_identities', 'Posting identities, grants, and user posting contexts are Fedibird resources with their own API. Not preferences.', 'app/controllers/settings/user_posting_contexts_controller.rb'),
        exclusion('excluded.web_push_subscription', 'InitialState push_subscription is a Web::PushSubscription row, not a preference.', 'app/models/web/push_subscription.rb'),
        exclusion('excluded.fedibird_api_surface', 'api/v1/fedibird covers translation languages, posting identities, and posting contexts. None of those controllers reads User.settings preference keys.', 'app/controllers/api/v1/fedibird/translation_languages_controller.rb'),
      ]
    end

    def exclusion(key, note, ref)
      {
        'key' => key,
        'category' => 'excluded',
        'owner' => 'excluded',
        'disposition' => 'excluded',
        'storage' => 'not User.settings',
        'legacy_keys' => { 'surface' => key },
        'raw_type' => 'not_a_preference',
        'effective_type' => 'not_a_preference',
        'default_source' => 'not_applicable',
        'read_sources' => ['own controller or serializer'],
        'write_sources' => ['own controller'],
        'normalization' => 'not_applicable',
        'availability' => 'separate settings surface',
        'read_policy' => 'exclude',
        'write_policy' => 'exclude',
        'side_effects' => ['out_of_scope'],
        'apply_hint' => 'unknown',
        'client_reference' => ['excluded_surface'],
        'configured_vs_effective' => 'not_a_user_setting',
        'form_status' => 'absent',
        'source_refs' => [ref],
        'audit_status' => 'verified',
        'notes' => "#{note} Kept in the audit catalog so the surface is not dropped. Field-level expansion is intentionally out of scope.",
      }
    end

    def open_questions
      [
        {
          'id' => 'notification_emails_followed_param_mismatch',
          'status' => 'unresolved',
          'notes' => 'The notifications form submits notification_emails.followed. config/settings.yml defaults that key to false. user_settings_params permits followed_message and does not permit followed. Strong parameters therefore drop the checkbox. followed_message is not a key in the YAML hash or the form. This audit did not rewrite stored values.',
        },
        {
          'id' => 'notification_emails_duplicate_fields_for_not_executed',
          'status' => 'unresolved',
          'notes' => 'The notifications form renders two simple_fields_for :notification_emails blocks. Distinct keys should merge in Rack, but this audit did not submit the form. Do not treat that merge as executed.',
        },
        {
          'id' => 'scoped_settings_cache_outside_transaction',
          'status' => 'unresolved',
          'notes' => 'ScopedSettings#[]= calls update! and then Rails.cache.write. PreferencesController does not wrap the settings write and the user column update in one transaction. Hash reads return inside cache.fetch, so nested settings skip the cache write. Recorded for P2. Not changed here.',
        },
        {
          'id' => 'production_stored_values_not_sampled',
          'status' => 'unresolved',
          'notes' => 'No production or development database was read. How many users have nil, legacy booleans, or unknown translation values is not known. Defaults below describe code paths, not row counts.',
        },
        {
          'id' => 'web_settings_json_schema_open',
          'status' => 'unresolved',
          'notes' => 'The WebUI sends PUT /api/web/settings. Rails resource update accepts PATCH on the same action. Either method persists params[:data] without a permit list or schema. The Redux initialState is a client convention. Saved documents may contain keys this catalog does not list.',
        },
        {
          'id' => 'show_target_has_no_active_ui',
          'status' => 'unresolved',
          'notes' => 'show_target is permitted, delegated, defaulted, and copied into InitialState, and initial_state.js exports it. No form input and no other JavaScript import were found. A dynamic or non-import use would not show up in the import scan.',
        },
      ]
    end

    def extractor_limits
      [
        'Haml inputs are detected with a line regex, not a Haml parser. Inputs built outside .input :name are invisible, including inputs rendered from a partial or a helper.',
        'A form input is conditional while an indentation stack still holds a shallower "- if" or "- unless" line. The condition is not evaluated. The parser misses a condition in another file, a condition that is not written as "- if" or "- unless", and a commented parent whose child line is not itself a comment.',
        'Commented inputs are only those whose own line is a Haml comment. A commented parent block with an uncommented child would be counted as active.',
        'UserSettingsDecorator key lists are read from %w arrays only.',
        'JavaScript use is counted from static import { name } from an initial_state module. Re-exports, require, and string lookups are not followed. Import count zero means no such import was found, not that a runtime lookup is impossible.',
        'Redux meta hydrates the whole InitialState meta object, but preference keys are not read back from state.meta by the selectors found in this pass. dynamic_update_possible is therefore a structural observation.',
        'The checker does not boot Rails, connect to PostgreSQL, or connect to Redis.',
      ]
    end

    def category_for(var)
      return 'posting' if POSTING.include?(var)
      return 'translation' if TRANSLATION.include?(var) || var == 'new_features_policy'
      return 'privacy' if PRIVACY.include?(var)
      return 'safety' if %w[disable_post disable_reactions disable_follow disable_unfollow disable_block disable_domain_block disable_report disable_clear_all_notifications disable_account_delete prohibited_visibilities prohibited_words confirm_domain_block confirm_follow_from_bot unlocked_for_official_app].include?(var)
      return 'timelines' if var.include?('timeline') || var == 'aggregate_reblogs' || var == 'hide_bot_on_public_timeline'
      return 'reactions' if var.include?('reaction') || var.include?('emoji')
      return 'notifications' if var.end_with?('_modal')
      return 'appearance' if var.start_with?('theme') || var.include?('font') || var.include?('column') || var.start_with?('auto_play') || var.include?('avatar') || %w[advanced_layout display_media expand_spoilers reduce_motion disable_swiping system_font_ui use_blurhash use_pending_items crop_images trends].include?(var)

      'other'
    end

    def disposition_for(var, forms)
      return 'retained_inactive' if var == 'enable_local_timeline' || var == 'show_target'
      return 'candidate_high_risk' if HIGH_RISK_VARS.include?(var)

      active = forms.any? { |field| !field['commented'] }
      return 'retained_inactive' unless active || @facts[:permit]['scalars'].include?(var)

      'candidate_general'
    end

    def decorator_group_for(var)
      %w[boolean string integer profile nested].each do |group|
        return group if @facts[:decorator][group].include?(var) || (group == 'profile' && @facts[:decorator]['profile'].include?("setting_#{var}"))
      end
      'undeclared'
    end

    def raw_type_for(var, yaml, group)
      return 'string_or_nil_or_legacy_boolean' if var == 'show_translation_bar'
      return 'string' if var == 'default_privacy' || var == 'default_language'
      return 'integer_in_yaml_string_after_form_save' if NUMERIC_STRINGS.include?(var)
      return 'array' if var == 'prohibited_visibilities'
      return yaml['yaml_type'] if yaml && group != 'string'
      return 'string' if group == 'string'
      return 'boolean' if group == 'boolean'

      yaml ? yaml['yaml_type'] : 'nil'
    end

    def effective_type_for(var, yaml, group)
      return 'string enum always|target|never' if var == 'show_translation_bar'
      return 'string enum translated|bilingual|both' if var == 'translation_preferred_mode'
      return 'string visibility' if var == 'default_privacy'
      return 'string or nil' if var == 'default_language'
      return 'number_or_numeric_string' if NUMERIC_STRINGS.include?(var)
      return 'array of strings' if var == 'prohibited_visibilities'
      return 'boolean' if group == 'boolean' || (yaml && yaml['yaml_type'] == 'boolean')

      yaml ? yaml['yaml_type'] : 'unknown'
    end

    def default_source_for(var, yaml)
      case var
      when 'default_privacy'
        'no settings.yml key. User#setting_default_privacy returns the stored value, or private when account.locked, otherwise public. The stored value stays nil until a write.'
      when 'default_language'
        'no settings.yml key. setting_default_language is nil until saved. preferred_posting_language then falls back to users.locale and I18n.locale.'
      when 'show_translation_bar'
        'settings.yml value is nil. User#setting_show_translation_bar normalizes nil, legacy booleans, and unknown strings through new_features_policy without writing. Policy default is never for conservative, always for tester, and target otherwise.'
      when 'translation_preferred_mode'
        "settings.yml default translated. Unknown stored values read back as translated."
      when 'enable_local_timeline'
        'settings.yml default true, but InitialState meta.enable_local_timeline is the literal false for a signed-in user. The form input is commented out.'
      when 'theme', 'noindex'
        "unset user value uses the current unscoped Setting.#{var} (site row or its YAML default), not only the YAML default. ScopedSettings::DEFAULTING_TO_UNSCOPED."
      when 'trends'
        'user YAML default true. InitialState meta.trends and meta.show_trends are Setting.trends && user.setting_trends. The site flag can hide trends while the user value stays true.'
      else
        if yaml
          "config/settings.yml defaults.#{var}=#{yaml['value'].inspect} (#{yaml['yaml_type']})"
        else
          'no config/settings.yml key. ScopedSettings returns nil when the user has no row. Nil is falsy at call sites that use the value as a boolean.'
        end
      end
    end

    def legacy_keys(var, forms, initial)
      keys = {
        'settings_var' => var,
        'getter' => "setting_#{var}",
        'form' => forms.empty? ? nil : "setting_#{var}",
      }
      keys['initial_state_meta'] = var if initial.any? { |ref| ref['text'].include?("store[:#{var}]") || ref['text'].include?('enable_local_timeline') }
      keys['initial_state_meta'] = 'translation_bar_visibility' if var == 'show_translation_bar'
      keys['initial_state_compose'] = compose_alias(var)
      keys['preferences_api'] = preferences_alias(var)
      keys['credentials_source'] = credentials_alias(var)
      keys.compact
    end

    def compose_alias(var)
      return 'default_privacy' if var == 'default_privacy'
      return 'default_sensitive' if var == 'default_sensitive'
      return 'default_language via preferred_posting_language' if var == 'default_language'
      return 'default_expires_in' if var == 'default_expires_in'
      return 'default_expires_action' if var == 'default_expires_action'
      return 'prohibited_visibilities filtered' if var == 'prohibited_visibilities'
      return 'prohibited_words split on comma' if var == 'prohibited_words'

      nil
    end

    def preferences_alias(var)
      return 'posting:default:visibility' if var == 'default_privacy'
      return 'posting:default:sensitive' if var == 'default_sensitive'
      return 'posting:default:language via preferred_posting_language, not the raw setting' if var == 'default_language'
      return 'reading:expand:media (enum string, not a boolean)' if var == 'display_media'
      return 'reading:expand:spoilers' if var == 'expand_spoilers'
      return 'reading:autoplay:gifs is the AND of four autoplay settings, not this flag alone' if var.start_with?('auto_play_')

      nil
    end

    def credentials_alias(var)
      return 'source.privacy' if var == 'default_privacy'
      return 'source.sensitive' if var == 'default_sensitive'
      return 'source.language (raw setting_default_language)' if var == 'default_language'

      nil
    end

    def read_sources_for(var, initial, js, css, html)
      sources = []
      sources << 'InitialState meta via setting_*' if initial.any?
      sources << 'InitialState compose' if compose_alias(var)
      sources << 'InitialState search.default_searchability' if var == 'default_search_searchability'
      sources << 'GET /api/v1/preferences' if preferences_alias(var) && !var.start_with?('auto_play_')
      sources << 'GET /api/v1/preferences as part of reading:autoplay:gifs' if var.start_with?('auto_play_')
      sources << 'GET /api/v1/accounts/verify_credentials source' if credentials_alias(var)
      sources << "static JS import #{js['export']} (#{js['importers']} importers)" if js && js['importers'].positive?
      sources << 'static JS export with no import found' if js && js['importers'].zero?
      sources << 'server CSS variables in account_theme_valiables' if css
      sources << 'server HTML body class or theme stylesheet' if html.any? || var == 'theme'
      sources << 'Rails preferences form getter' if form_hits(var).any?
      sources << 'no client read found' if sources.empty?
      sources
    end

    def write_sources_for(var, forms)
      sources = []
      if @facts[:permit]['scalars'].include?(var)
        pages = forms.reject { |field| field['commented'] }.map { |field| field['path'][%r{preferences/(\w+)/}, 1] || 'preferences' }.uniq
        form_source = if LEGACY_FORM_KEYS.include?(var)
                        if pages.empty?
                          'permitted on preferences update and saved through LegacyWriter when the form passes one, but no active input submits it'
                        else
                          "rails preferences update via LegacyWriter (#{pages.join(', ')})"
                        end
                      elsif pages.empty?
                        'permitted by every Settings::PreferencesController#update, but no active input submits it'
                      else
                        "rails preferences update (#{pages.join(', ')})"
                      end
        sources << form_source
      end
      sources << 'commented form input; the shared permit list still accepts the parameter' if forms.any? { |field| field['commented'] } && @facts[:permit]['scalars'].include?(var)
      sources << 'PATCH /api/v1/accounts/update_credentials source via UserSettingsDecorator without legacy_writer' if %w(default_privacy default_sensitive default_language).include?(var)
      sources << 'no write path found' if sources.empty?
      sources
    end

    def write_sources_nested(in_permit, forms)
      sources = []
      sources << 'rails.preferences.notifications' if forms.any? { |field| !field['commented'] }
      sources << 'permitted nested key' if in_permit
      sources << 'not permitted, so the form value is dropped' if !in_permit && forms.any?
      sources << 'no write path found' if sources.empty?
      sources
    end

    def normalization_for(var, group)
      case var
      when 'show_translation_bar'
        'On write, TranslationPreferences.normalize_visibility. true becomes always, false becomes never, always|target|never are kept, and any other value becomes the new_features_policy default. The policy read during that write is the previously stored policy, because show_translation_bar is normalized before new_features_policy in STRING_KEYS. On read, the same function runs and does not save. JavaScript normalizeTranslationBarVisibility maps an unknown string to null instead of the policy default. InitialState already sends the Ruby effective value.'
      when 'translation_preferred_mode'
        'TranslationPreferences.normalize_preferred_mode keeps translated, bilingual, and both. Anything else becomes translated on read and on write. The display mode original is per-status UI state and is not a stored preference.'
      when 'default_privacy'
        'Stored as the submitted string. The getter replaces only a blank stored value. Selectable form values are Status.selectable_visibilities: public, unlisted, private, mutual, personal.'
      when 'default_language'
        'Stored as submitted, including nil for the language-detection option. The getter does not cascade. preferred_posting_language does.'
      when 'prohibited_words'
        'Stored as a string. InitialState and post services split on comma, strip, and drop blanks. The split array is not what is stored.'
      when 'prohibited_visibilities'
        'Stored from a check box array. InitialState drops blank entries. INTEGER_KEYS is empty, so this is not integer-cast.'
      else
        if NUMERIC_STRINGS.include?(var)
          'Listed in STRING_KEYS, so the decorator stores the form value without Integer() or Float(). YAML defaults are numeric. After a Rails save the stored YAML value can be a string. CSS interpolates either. max_frequently_used_emojis is also validated as a number on User and Number()-cast once in initial_state.js.'
        elsif group == 'boolean'
          'ActiveModel::Type::Boolean on write. Simple Form sends 0 or 1. Read returns the stored YAML boolean or the YAML default. No integer cast; INTEGER_KEYS is empty.'
        elsif group == 'string'
          'Stored as the submitted string with no extra cast.'
        else
          'unknown'
        end
      end
    end

    def availability_for(var, forms)
      return 'signed-in InitialState forces false; form input is commented; Fedibird does not offer a local timeline. Do not treat the settings.yml default true as availability.' if var == 'enable_local_timeline'
      return 'form input is absent. The value is still permitted on preferences update.' if var == 'show_target'
      return 'form inputs render only when setting_new_features_policy equals tester. The permit list still accepts them on every preferences update.' if %w[enable_status_polling enable_status_polling_intersection].include?(var)
      return 'effective WebUI flag is site Setting.trends AND the user value' if var == 'trends'
      return 'user theme is used only when it is one of Themes.instance.names; otherwise the unscoped site theme is used. Another account theme is used when viewing that account if theme_public is set.' if var == 'theme'

      conditional = forms.select { |field| field['conditional'] }
      return "form condition: #{conditional.map { |field| field['condition'] }.uniq.join(' | ')}" if conditional.any?

      'user preference'
    end

    def read_policy_for(var)
      return 'general' if credentials_alias(var) || preferences_alias(var)

      'general'
    end

    def write_policy_for(var, forms)
      return 'not_writable' if var == 'enable_local_timeline'
      return 'high_risk' if HIGH_RISK_VARS.include?(var)
      return 'not_writable' if forms.empty? && var == 'show_target'

      'general'
    end

    def side_effects_for(var, css, html)
      effects = if LEGACY_FORM_KEYS.include?(var)
                  decorator_path = if %w(default_privacy default_sensitive default_language).include?(var)
                                     'Credentials and UserSettingsDecorator without legacy_writer: ScopedSettings#[]= update! and Rails.cache.write, no revision'
                                   else
                                     'UserSettingsDecorator without legacy_writer: ScopedSettings#[]= update! and Rails.cache.write, no revision'
                                   end
                  [
                    'form LegacyWriter: a real change advances revision and after COMMIT runs rewrite_cache, legacy cache delete, and preferences_changed; a same-value resubmit does not',
                    decorator_path,
                  ]
                else
                  ['settings row update and Rails.cache.write in ScopedSettings#[]=']
                end
      effects << 'ActivityPub::UpdateDistributionWorker when the preferences params include this key; the check is key presence, not value change' if PROFILE_VARS.include?(var)
      effects << 'fan-out skips direct or personal delivery to self' if %w[hide_direct_from_timeline hide_personal_from_timeline].include?(var)
      effects << 'account statuses API filters personal visibility' if var == 'hide_personal_from_account'
      effects << 'PostStatusService and status update reject prohibited words' if var == 'prohibited_words'
      effects << 'statuses API and posting identity refuse posting' if var == 'disable_post'
      effects << 'follow API refuses a new follow' if var == 'disable_follow'
      effects << 'verify_credentials and accounts#show mask account.locked in memory for official iOS or Android apps' if var == 'unlocked_for_official_app'
      effects << 'account serializer redacts counts, follows, or media urls' if var.start_with?('hide_') || var == 'use_low_resolution_thumbnails' || var.start_with?('use_fullsize_')
      effects << 'document CSS variables; reload required' if css
      effects << 'body class or theme stylesheet; reload required' if html.any? || var == 'theme'
      effects << 'columns_area componentDidMount removes the matching column' if %w[enable_local_timeline enable_federated_timeline enable_limited_timeline].include?(var)
      effects
    end

    def apply_hint_for(var, js, css, html, initial)
      return 'unknown' if var == 'enable_local_timeline'
      return 'reload' if css || html.any? || var == 'theme' || var == 'system_font_ui'
      return 'live' if var == 'hide_personal_from_account'
      return 'unknown' if js && js['importers'].zero?
      return 'reinitialize' if js && js['importers'].positive?
      return 'reinitialize' if initial.any?
      return 'live' if form_hits(var).empty?

      'reinitialize'
    end

    def client_reference_for(var, js, css, html, initial)
      refs = []
      sections = initial.map { |ref| ref['section'] }.compact.uniq
      refs << 'static_import' if js && js['importers'].positive?
      refs << 'unused_export' if js && js['importers'].zero?
      refs << 'redux_meta_hydrated_unread' if sections.include?('meta')
      refs << 'redux_compose' if sections.include?('compose')
      refs << 'redux_search' if sections.include?('search')
      refs << 'css_variable' if css
      refs << 'server_html' if html.any? || var == 'theme'
      refs << 'component_init_only' if %w[enable_local_timeline enable_federated_timeline enable_limited_timeline].include?(var)
      refs << 'none' if refs.empty?
      refs << 'dynamic_update_possible_if_selectors_replace_static_imports' if sections.include?('meta') && !css && html.empty? && var != 'theme'
      refs
    end

    def configured_vs_effective_for(var, initial)
      return 'distinct' if %w[default_privacy default_language show_translation_bar translation_preferred_mode trends enable_local_timeline theme noindex default_search_searchability].include?(var)
      return 'distinct_literal_false' if initial.any? { |ref| ref['literal'] == false }
      return 'type_may_diverge_after_form_save' if NUMERIC_STRINGS.include?(var)
      return 'unset_is_nil' unless yaml_by_key[var]

      'effective_is_stored_or_yaml_default'
    end

    def form_status(forms)
      return 'absent' if forms.empty?
      return 'commented' if forms.all? { |field| field['commented'] }
      return 'conditional' if forms.any? { |field| field['conditional'] }

      'active'
    end

    def form_hits(var)
      @facts[:forms].each_value.flat_map do |fields|
        fields.select { |field| field['nested'].nil? && field['name'] == "setting_#{var}" }
      end
    end

    def js_for_meta(var)
      meta = var == 'show_translation_bar' ? 'translation_bar_visibility' : var
      export = @facts[:js_meta].find { |row| row['meta'] == meta }
      return unless export

      {
        'export' => export['export'],
        'line' => export['line'],
        'importers' => @facts[:js_imports]['counts'][export['export']] || 0,
        'number' => export['number'],
      }
    end

    def source_refs_for(var, yaml, forms, initial, js, css, html, group)
      refs = []
      refs << "config/settings.yml:#{yaml['line']}" if yaml && yaml['line']
      refs << "app/lib/user_settings_decorator.rb:#{@facts[:decorator]['lines'][var]}" if @facts[:decorator]['lines'][var]
      refs << "app/lib/user_preferences/legacy_writer.rb:#{read_line('app/lib/user_preferences/legacy_writer.rb', 'def update')}" if LEGACY_FORM_KEYS.include?(var)
      refs << "app/models/user.rb:#{@facts[:delegate]['line']}" if @facts[:delegate]['keys'].include?(var)
      refs << "app/models/user.rb:#{read_line('app/models/user.rb', 'def setting_default_privacy')}" if var == 'default_privacy'
      refs << "app/models/user.rb:#{read_line('app/models/user.rb', 'def setting_show_translation_bar')}" if var == 'show_translation_bar'
      refs << "app/models/user.rb:#{read_line('app/models/user.rb', 'def setting_translation_preferred_mode')}" if var == 'translation_preferred_mode'
      refs << "app/controllers/settings/preferences_controller.rb:#{@facts[:permit]['line']}" if @facts[:permit]['scalars'].include?(var)
      forms.each { |field| refs << "#{field['path']}:#{field['line']}" }
      initial.each { |ref| refs << "app/serializers/initial_state_serializer.rb:#{ref['line']}" }
      refs << "app/javascript/mastodon/initial_state.js:#{js['line']}" if js
      refs << "app/helpers/accounts_helper.rb:#{@facts[:css_vars]['line']}" if css
      html.each { |row| refs << "app/helpers/application_helper.rb:#{row['line']}" }
      refs << "app/controllers/application_controller.rb:#{@facts[:html_classes]['theme_line']}" if var == 'theme'
      refs << 'app/lib/translation_preferences.rb:11' if var == 'show_translation_bar'
      refs << 'app/lib/translation_preferences.rb:36' if var == 'translation_preferred_mode'
      refs.compact.uniq
    end

    def notes_for(var, yaml, forms, group, initial, js)
      parts = []
      parts << 'Recommendation only: read_policy and write_policy are not an approved API contract.'
      parts << "Decorator group #{group}."
      parts << 'Getter is delegated to ScopedSettings with prefix setting.' if @facts[:delegate]['keys'].include?(var)
      parts << 'Getter is an override on User and is not the raw stored value.' if %w[default_privacy show_translation_bar translation_preferred_mode].include?(var)
      parts << 'Not listed in the User delegate. Call sites use the override or settings[] directly.' if !@facts[:delegate]['keys'].include?(var) && !%w[default_privacy show_translation_bar translation_preferred_mode].include?(var)
      parts << 'No settings.yml default.' unless yaml
      parts << 'Active form input is commented out.' if forms.any? { |field| field['commented'] }
      parts << 'InitialState assigns the literal false and does not read the stored setting.' if initial.any? { |ref| ref['literal'] == false }
      parts << "JavaScript captures #{js['export']} at module evaluation. #{js['importers']} import sites. Redux meta also receives the value on hydrate, but scanned selectors do not read it from state.meta." if js
      parts << 'Changing the stored value does not by itself update the open WebUI.' if %w[reinitialize reload].include?(apply_hint_for(var, js, @facts[:css_vars]['vars'].include?(var), @facts[:html_classes]['vars'].select { |row| row['var'] == var }, initial))
      if var == 'default_search_searchability'
        parts << 'InitialState search.default_searchability uses this user setting. InitialState compose.default_searchability uses accounts.searchability. The composer reducer default before hydrate is private. These are different values.'
      end
      if var == 'default_privacy'
        parts << 'A share URL can also set InitialStatePresenter visibility for that response only, and compose.default_privacy prefers that visibility over this setting. Saving the other preferences form submits the getter, so a previously unset value becomes stored.'
      end
      parts.join(' ')
    end

    def special_case(var)
      nil
    end

    def audit_status_for(_entry, var)
      return 'unresolved' if var == 'show_target'

      'verified'
    end

    def nested_availability(group, child, forms)
      return 'form input only when current_user.administrative?' if %w[report pending_account].include?(child)
      return 'form input only when current_user.can?(:manage_taxonomies)' if child == 'trends' && group == 'notification_emails'
      return 'form submits this name but strong parameters do not permit it' if child == 'followed'
      return 'permitted but the notifications form does not render it' if child == 'followed_message'

      forms.any? ? 'notifications form' : 'hash default only'
    end

    def nested_notes(group, child, in_yaml, in_permit, forms, yaml_value)
      parts = ["Nested key of #{group}. YAML present=#{in_yaml} default=#{yaml_value.inspect}. Permitted=#{in_permit}. Form inputs=#{forms.size}."]
      parts << 'Recommendation only: write_policy high_risk for interactions because NotifyService drops notifications and some direct messages when the flag is set.' if group == 'interactions'
      parts << 'Email lookup uses notification.type, so the followed notification reads notification_emails.followed. The form checkbox uses that key, but it is not permitted. followed_message is a different name and collides with the account profile field.' if child == 'followed' || child == 'followed_message'
      parts << 'write_policy not_writable is the future API recommendation. write_sources still records the current Rails permit list, which accepts this key even though no form submits it.' if child == 'followed_message'
      parts << 'Staff-only inputs are omitted for other users, and the decorator merges only submitted keys, so a hidden key is left unchanged.' if %w[report pending_account trends].include?(child) && group == 'notification_emails'
      parts << 'must_be_dm_to_send_email gates email only. The other interaction flags gate notification creation.' if child == 'must_be_dm_to_send_email'
      parts.join(' ')
    end

    def nested_refs(group, child, forms)
      refs = ["config/settings.yml:#{yaml_by_key[group]['line']}", "app/lib/user_settings_decorator.rb:#{read_line('app/lib/user_settings_decorator.rb', 'NESTED_KEYS = %w(')}", "app/controllers/settings/preferences_controller.rb:#{@facts[:permit]['line']}", 'app/services/notify_service.rb:78']
      forms.each { |field| refs << "#{field['path']}:#{field['line']}" }
      refs << "app/models/user.rb:#{read_line('app/models/user.rb', 'def allows_digest_emails?')}" if %w[digest report pending_account trends].include?(child)
      refs.uniq
    end

    def column_refs(column)
      line = read_line('app/models/user.rb', column == 'chosen_languages' ? 'def sanitize_languages' : "def sanitize_#{column == 'locale' ? 'locale' : 'time_zone'}")
      ["app/models/user.rb:#{line}", "app/controllers/settings/preferences_controller.rb:#{read_line('app/controllers/settings/preferences_controller.rb', 'def user_params')}"]
    end

    def account_storage(name)
      json = %w[followed_message birthday birth_year birth_month birth_day location]
      return "accounts.settings JSON key #{name} via AccountSettings" if json.include?(name)
      return 'accounts.searchability enum, default direct' if name == 'searchability'
      return 'account media attachment' if %w[avatar header].include?(name)
      return 'account.fields association' if name == 'fields'

      "accounts.#{name}"
    end

    def account_note(name)
      base = 'Profile management, not a User.settings preference. Excluded from the settings API candidate list and kept so the profile form is still in the audit.'
      return "#{base} compose.default_searchability hydrates from this column. The user setting of the same idea is user.default_search_searchability and hydrates search.default_searchability." if name == 'searchability'
      return "#{base} When user.default_privacy is unset, the effective privacy getter reads account.locked." if name == 'locked'
      return "#{base} discoverable is rendered only when Setting.profile_directory is true." if name == 'discoverable'
      return "#{base} Stored in accounts.settings, the same JSON bucket as birthday and location. The name followed_message also appears, unused, in notification email strong parameters." if name == 'followed_message'

      base
    end

    def credentials_account_param?(name)
      source = File.read(File.join(@root, 'app/controllers/api/v1/accounts/credentials_controller.rb'))
      source.include?(":#{name}")
    end

    def admin_keys
      source = File.read(File.join(@root, 'app/models/form/admin_settings.rb'))
      body = source[/KEYS = %i\(\s*(.*?)\s*\)\.freeze/m, 1]
      body.scan(/[A-Za-z0-9_]+/)
    end

    def nested_disposition(group, in_yaml, forms)
      return 'candidate_high_risk' if group == 'interactions'
      return 'retained_inactive' if !in_yaml && forms.empty?

      'candidate_general'
    end

    def site_reader_files(key)
      @ruby_sources ||= Dir.glob(File.join(@root, 'app/**/*.{rb,haml}')).map { |path| [path.delete_prefix("#{@root}/"), File.read(path)] }
      pattern = /Setting(?:\.#{key}\b|\[['"]#{key}['"]\])/
      @ruby_sources.filter_map { |path, text| path if text.match?(pattern) }
    end

    def site_note(key, admin_key, readers)
      if key == 'min_invite_role'
        'Legacy instance setting. Form::AdminSettings::KEYS no longer includes it; db/legacy_role_setting_sync.rb still reads the stored value when migrating invite permissions onto UserRole. No current admin field. Retained. audit_status inferred because the migration is historical and this pass did not execute it.'
      elsif key == 'disallowed_hashtags'
        'config/settings.yml still has disallowed_hashtags. DisallowedHashtagsValidator does not read Setting.disallowed_hashtags; it rejects tags Tag#usable? is false for. No Setting.disallowed_hashtags reader was found under app/. Retained so the key is not deleted on name similarity alone.'
      elsif key == 'enable_personal_account'
        'Present only in config/settings.yml. No Setting.enable_personal_account reader was found under app/. This is not enable_personal_timeline. Retained as an inactive key. audit_status inferred because a dynamic send could still reference it.'
      elsif admin_key
        'Instance setting. It shares config/settings.yml with user defaults. Listed so it is not mistaken for a per-user preference and is not dropped from the audit. Not a Settings Service user-API candidate.'
      elsif readers.empty?
        'In config/settings.yml but not in the user decorator and no Setting.key reader was found under app/. Retained. audit_status inferred because this is a negative search.'
      else
        "Read as an unscoped Setting. Readers: #{readers.join(', ')}. Not a user preference candidate."
      end
    end

    def nested_write_policy(group, in_yaml, forms)
      return 'not_writable' if nested_disposition(group, in_yaml, forms) == 'retained_inactive'
      return 'high_risk' if group == 'interactions'

      'general'
    end

    def read_line(path, snippet)
      File.readlines(File.join(@root, path)).index { |line| line.include?(snippet) } + 1
    end
  end
end
