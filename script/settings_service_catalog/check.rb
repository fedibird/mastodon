# frozen_string_literal: true

require 'yaml'
require_relative 'extract'
require_relative 'build'

module SettingsServiceCatalog
  class Check
    REQUIRED = %w[
      key category owner disposition storage legacy_keys raw_type effective_type
      default_source read_sources write_sources normalization availability
      read_policy write_policy side_effects apply_hint client_reference
      configured_vs_effective form_status source_refs audit_status notes
    ].freeze
    APPLY_HINTS = %w[live reinitialize reload unknown].freeze
    AUDIT = %w[verified inferred unresolved].freeze
    DISPOSITIONS = %w[
      candidate_general candidate_high_risk retained_inactive excluded site client
      user_column derived account
    ].freeze
    POLICIES = %w[general high_risk exclude admin not_writable session_web unresolved].freeze

    def initialize(root:, catalog_path:, skip_generated: false)
      @root = root
      @catalog_path = catalog_path
      @skip_generated = skip_generated
      @errors = []
      @warnings = []
    end

    def run
      catalog = YAML.safe_load(File.read(@catalog_path), aliases: true)
      facts = Extract.new(@root).call
      entries = catalog.fetch('entries')
      keys = entries.map { |entry| entry['key'] }
      duplicate = keys.group_by(&:itself).select { |_key, values| values.size > 1 }.keys
      @errors << "duplicate keys: #{duplicate.join(', ')}" unless duplicate.empty?

      entries.each { |entry| validate_entry(entry) }
      validate_source_refs(entries)
      validate_coverage(entries, facts)
      validate_open_questions(catalog, facts)
      validate_stats(catalog, entries, facts)
      validate_inactive_write_policy(entries)
      validate_limits(catalog)
      validate_generated(catalog) unless @skip_generated

      {
        'ok' => @errors.empty?,
        'errors' => @errors,
        'warnings' => @warnings,
        'entries' => entries.size,
        'unresolved_entries' => entries.count { |entry| entry['audit_status'] == 'unresolved' },
        'unresolved_questions' => Array(catalog['open_questions']).size,
        'by_disposition' => entries.group_by { |entry| entry['disposition'] }.transform_values(&:size).sort.to_h,
        'by_audit_status' => entries.group_by { |entry| entry['audit_status'] }.transform_values(&:size).sort.to_h,
      }
    end

    private

    def validate_entry(entry)
      key = entry['key'] || '(missing key)'
      REQUIRED.each do |field|
        value = entry[field]
        @errors << "#{key} missing #{field}" if value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
      @errors << "#{key} apply_hint #{entry['apply_hint']}" unless APPLY_HINTS.include?(entry['apply_hint'])
      @errors << "#{key} audit_status #{entry['audit_status']}" unless AUDIT.include?(entry['audit_status'])
      @errors << "#{key} unclassified disposition #{entry['disposition']}" unless DISPOSITIONS.include?(entry['disposition'])
      @errors << "#{key} read_policy #{entry['read_policy']}" unless POLICIES.include?(entry['read_policy'])
      @errors << "#{key} write_policy #{entry['write_policy']}" unless POLICIES.include?(entry['write_policy'])
      @errors << "#{key} excluded entry has no explanation" if entry['disposition'] == 'excluded' && entry['notes'].to_s.length < 20
      @errors << "#{key} source_refs must name a file" unless Array(entry['source_refs']).all? { |ref| ref.include?('/') || ref.include?('.rb') || ref.include?('.yml') || ref.include?('.js') || ref.include?('.haml') }
    end

    def validate_coverage(entries, facts)
      by_key = entries.to_h { |entry| [entry['key'], entry] }
      user_vars = (facts[:decorator]['boolean'] + facts[:decorator]['string'] + facts[:decorator]['integer'] + facts[:delegate]['keys'] + facts[:permit]['scalars']).uniq
      user_vars.each do |var|
        @errors << "user setting #{var} is not in the catalog" unless by_key["user.#{var}"]
      end

      %w[notification_emails interactions].each do |group|
        yaml_keys = hash_keys(facts, group)
        permit_keys = facts[:permit]['nested'][group] || []
        form_keys = facts[:forms]['notifications'].select { |field| field['nested'] == group }.map { |field| field['name'] }
        (yaml_keys + permit_keys + form_keys).uniq.each do |child|
          entry = by_key["user.#{group}.#{child}"]
          @errors << "nested setting #{group}.#{child} is not in the catalog" unless entry
          next unless entry

          disagree = !yaml_keys.include?(child) || !permit_keys.include?(child) || !form_keys.include?(child)
          @errors << "#{entry['key']} disagrees across yaml/form/permit and cannot be verified" if disagree && entry['audit_status'] == 'verified'
        end
      end

      facts[:forms].each do |page, fields|
        fields.each do |field|
          catalog_key = catalog_key_for_form(page, field)
          entry = by_key[catalog_key]
          @errors << "form #{field['path']}:#{field['line']} #{field['name']} is not in the catalog (expected #{catalog_key})" unless entry
          next unless entry

          expected = if field['commented']
                       'commented'
                     elsif field['conditional']
                       'conditional'
                     else
                       'active'
                     end
          @errors << "#{catalog_key} form_status is #{entry['form_status']} but #{field['path']}:#{field['line']} is #{expected}" unless entry['form_status'] == expected
        end
      end

      facts[:initial_state]['setting_refs'].map { |ref| ref['var'] }.uniq.each do |var|
        @errors << "InitialState setting #{var} is not in the catalog" unless by_key["user.#{var}"]
      end

      local = by_key['user.enable_local_timeline']
      if local
        @errors << 'enable_local_timeline must keep configured and effective distinct' unless local['configured_vs_effective'].include?('distinct')
        @errors << 'enable_local_timeline notes must record the forced false' unless local['notes'].include?('false')
        @errors << 'enable_local_timeline must not be classified as an available writable feature' if local['disposition'] == 'candidate_general' || local['write_policy'] == 'general'
      end

      privacy = by_key['user.default_privacy']
      if privacy
        @errors << 'default_privacy must distinguish configured and effective values' unless privacy['configured_vs_effective'] == 'distinct'
        @errors << 'default_privacy notes must mention account.locked' unless privacy['notes'].include?('locked') || privacy['default_source'].include?('locked')
      end

      language = by_key['derived.preferred_posting_language']
      @errors << 'preferred_posting_language derived entry missing' unless language
      if language && language['notes'].include?('synonym') && language['configured_vs_effective'] != 'distinct'
        @errors << 'preferred posting language must stay distinct from the raw setting'
      end

      consumed = user_vars + %w[notification_emails interactions]
      facts[:yaml].each do |row|
        next if consumed.include?(row['key'])

        @errors << "settings.yml #{row['key']} is not in the catalog" unless by_key["site.#{row['key']}"]
      end

      exclusion_refs = entries.select { |entry| entry['disposition'] == 'excluded' }.flat_map { |entry| entry['source_refs'] }
      @errors << 'exclusion list is empty' if exclusion_refs.empty?
      exclusion_refs.each do |ref|
        path = ref.split(':').first
        @errors << "exclusion source missing on disk: #{path}" unless File.exist?(File.join(@root, path))
      end
    end

    def validate_open_questions(catalog, facts)
      questions = catalog['open_questions']
      @errors << 'open_questions missing' unless questions.is_a?(Array) && !questions.empty?
      return unless questions.is_a?(Array)

      questions.each do |question|
        @errors << "open question #{question['id']} is not explicitly unresolved" unless question['status'] == 'unresolved'
        @errors << "open question #{question['id']} has no notes" if question['notes'].to_s.strip.empty?
      end
      ids = questions.map { |question| question['id'] }
      permit = facts[:permit]['nested']['notification_emails'] || []
      form = facts[:forms]['notifications'].select { |field| field['nested'] == 'notification_emails' }.map { |field| field['name'] }
      if form.include?('followed') && !permit.include?('followed')
        @errors << 'followed form/permit mismatch must stay in open_questions' unless ids.include?('notification_emails_followed_param_mismatch')
      end
      @errors << 'cache transaction question must stay unresolved' unless ids.include?('scoped_settings_cache_outside_transaction')
      @errors << 'database sampling limit must stay visible' unless ids.include?('production_stored_values_not_sampled')
    end

    def validate_stats(catalog, entries, facts)
      stats = catalog.dig('meta', 'stats') || {}
      @errors << 'meta.stats.entries drift' unless stats['entries'] == entries.size
      @errors << 'meta.stats.by_audit_status drift' unless stats['by_audit_status'] == tally(entries, 'audit_status')
      @errors << 'meta.stats.by_disposition drift' unless stats['by_disposition'] == tally(entries, 'disposition')
      @errors << 'meta.stats.by_owner drift' unless stats['by_owner'] == tally(entries, 'owner')
      @errors << 'meta.stats.form_inputs drift' unless stats['form_inputs'] == form_input_stats(facts)
      @errors << 'meta.not_runtime_contract must stay true' unless catalog.dig('meta', 'not_runtime_contract') == true
    end

    def validate_inactive_write_policy(entries)
      entries.each do |entry|
        next unless entry['disposition'] == 'retained_inactive'
        next if entry['write_policy'] == 'not_writable'

        @errors << "#{entry['key']} retained_inactive write_policy must be not_writable, found #{entry['write_policy']}"
      end
    end

    def validate_source_refs(entries)
      entries.each do |entry|
        Array(entry['source_refs']).each do |ref|
          path, line = split_source_ref(ref)
          full = File.join(@root, path)
          unless File.file?(full)
            @errors << "#{entry['key']} source_ref missing file #{path}"
            next
          end
          next if line.nil?

          lines = File.readlines(full)
          if line < 1 || line > lines.size
            @errors << "#{entry['key']} source_ref #{ref} is outside #{path} (#{lines.size} lines)"
          elsif lines[line - 1].strip.empty?
            @errors << "#{entry['key']} source_ref #{ref} points at a blank line"
          end
        end
      end
    end

    def validate_generated(catalog)
      generated = canonicalize(Build.new(@root).document)
      committed = canonicalize(catalog)
      return if generated == committed

      @errors.concat(catalog_drift(committed, generated))
    end

    def validate_limits(catalog)
      limits = catalog['extractor_limits']
      @errors << 'extractor limits were omitted' unless limits.is_a?(Array) && limits.size >= 3
      joined = Array(limits).join("\n")
      @errors << 'extractor_limits still describes the old 12-line condition window' if joined.include?('12 lines')
      @errors << 'extractor_limits must describe the indentation stack' unless joined.include?('indentation stack')
      @warnings << 'static extraction is incomplete by design; unresolved questions are listed and are not successes' if limits.is_a?(Array)
    end

    def tally(entries, field)
      entries.group_by { |entry| entry[field] }.transform_values(&:size)
    end

    def form_input_stats(facts)
      facts[:forms].transform_values do |fields|
        {
          'active' => fields.count { |field| !field['commented'] },
          'commented' => fields.count { |field| field['commented'] },
          'conditional' => fields.count { |field| field['conditional'] },
        }
      end
    end

    def split_source_ref(ref)
      return [ref, nil] unless ref =~ /\A(.+):(\d+)\z/

      [Regexp.last_match(1), Regexp.last_match(2).to_i]
    end

    def canonicalize(document)
      YAML.safe_load(YAML.dump(document), aliases: true)
    end

    def catalog_drift(committed, generated)
      errors = []
      committed_entries = Array(committed['entries']).to_h { |entry| [entry['key'], entry] }
      generated_entries = Array(generated['entries']).to_h { |entry| [entry['key'], entry] }
      (committed_entries.keys - generated_entries.keys).each { |key| errors << "generator dropped #{key}" }
      (generated_entries.keys - committed_entries.keys).each { |key| errors << "generator added #{key} missing from catalog" }
      (committed_entries.keys & generated_entries.keys).each do |key|
        next if committed_entries[key] == generated_entries[key]

        fields = (committed_entries[key].keys | generated_entries[key].keys).reject { |field| committed_entries[key][field] == generated_entries[key][field] }
        errors << "catalog drift #{key} fields: #{fields.join(', ')}"
      end
      %w[open_questions extractor_limits].each do |section|
        errors << "catalog drift #{section}" unless committed[section] == generated[section]
      end
      errors << 'catalog drift meta' unless committed['meta'] == generated['meta']
      errors.first(40)
    end

    def hash_keys(facts, group)
      row = facts[:yaml].find { |item| item['key'] == group }
      return [] unless row && row['value'].is_a?(Hash)

      row['value'].keys
    end

    def catalog_key_for_form(page, field)
      return "account.#{field['nested']}.#{field['name']}" if page == 'profile' && field['nested']
      return "account.#{field['name']}" if page == 'profile'
      return "user.#{field['nested']}.#{field['name']}" if field['nested']
      return "user.#{field['name']}" if %w[locale time_zone chosen_languages].include?(field['name'])

      "user.#{field['name'].delete_prefix('setting_')}"
    end
  end
end
