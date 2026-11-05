# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'
require 'fileutils'

class CheckSettingsServiceCatalogTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CHECK = File.join(ROOT, 'script/check_settings_service_catalog.rb')
  CATALOG = File.join(ROOT, 'docs/settings_service/catalog.yml')

  def test_real_catalog_passes_without_booting_rails
    output, status = run_check(CATALOG)
    assert status.success?, output
    assert_match(/entries: 270/, output)
    assert_match(/duplicate keys: 0/, output)
    assert_match(/"site"=>54/, output)
    assert_match(/"inferred"=>23/, output)
    assert_match(/"verified"=>244/, output)
    assert_match(/unresolved_entries: 3/, output)
    assert_match(/unresolved_questions: 6/, output)
    assert_match(/not treated as successes|unresolved/, output)
    refute_match(/error:/, output)
  end

  def test_catalog_keeps_configured_and_effective_distinct
    catalog = YAML.safe_load(File.read(CATALOG), aliases: true)
    privacy = entry(catalog, 'user.default_privacy')
    language = entry(catalog, 'user.default_language')
    derived = entry(catalog, 'derived.preferred_posting_language')
    bar = entry(catalog, 'user.show_translation_bar')
    local = entry(catalog, 'user.enable_local_timeline')
    search = entry(catalog, 'user.default_search_searchability')

    assert_equal 'distinct', privacy['configured_vs_effective']
    assert_includes privacy['default_source'], 'locked'
    assert_equal 'distinct', language['configured_vs_effective']
    assert_equal 'distinct', derived['configured_vs_effective']
    assert_includes derived['notes'], 'not synonyms'
    assert_equal 'distinct', bar['configured_vs_effective']
    assert_includes bar['normalization'], 'does not save'
    assert_equal 'retained_inactive', local['disposition']
    assert_includes local['default_source'], 'literal false'
    assert_equal 'distinct', search['configured_vs_effective']
    assert_includes search['notes'], 'accounts.searchability'
  end

  def test_excluded_and_unresolved_items_remain_visible
    catalog = YAML.safe_load(File.read(CATALOG), aliases: true)
    keys = catalog['entries'].map { |item| item['key'] }
    assert_includes keys, 'excluded.oauth_applications'
    assert_includes keys, 'excluded.external_credentials'
    assert_includes keys, 'account.followed_message'
    assert_includes keys, 'site.enable_personal_account'
    assert_includes keys, 'user.notification_emails.followed'
    assert_includes keys, 'user.notification_emails.followed_message'
    assert_equal 'unresolved', entry(catalog, 'user.notification_emails.followed')['audit_status']
    assert_equal 'unresolved', entry(catalog, 'user.show_target')['audit_status']
    assert_equal %w[unresolved], catalog['open_questions'].map { |question| question['status'] }.uniq
  end

  def test_duplicate_key_fails
    catalog = YAML.safe_load(File.read(CATALOG), aliases: true)
    catalog['entries'] << catalog['entries'].first.dup
    output, status = run_check(write_catalog(catalog))
    refute status.success?
    assert_match(/duplicate keys/, output)
  end

  def test_missing_user_setting_fails
    catalog = YAML.safe_load(File.read(CATALOG), aliases: true)
    catalog['entries'].reject! { |item| item['key'] == 'user.default_sensitive' }
    catalog['meta']['stats']['entries'] = catalog['entries'].size
    output, status = run_check(write_catalog(catalog))
    refute status.success?
    assert_match(/user setting default_sensitive is not in the catalog/, output)
  end

  def test_mismatch_cannot_be_marked_verified
    catalog = YAML.safe_load(File.read(CATALOG), aliases: true)
    entry(catalog, 'user.notification_emails.followed')['audit_status'] = 'verified'
    output, status = run_check(write_catalog(catalog))
    refute status.success?
    assert_match(/cannot be verified/, output)
  end

  def test_missing_required_metadata_fails
    catalog = YAML.safe_load(File.read(CATALOG), aliases: true)
    entry(catalog, 'user.default_privacy')['read_policy'] = ''
    output, status = run_check(write_catalog(catalog))
    refute status.success?
    assert_match(/missing read_policy/, output)
  end

  def test_extract_reads_the_worktree_user_model
    source = File.read(File.join(ROOT, 'script/settings_service_catalog/extract.rb'))
    refute_match(/git show HEAD/, source)
  end

  def test_user_delegate_change_is_detected
    path = File.join(ROOT, 'app/models/user.rb')
    original = File.binread(path)
    updated = original.sub('delegate :auto_play_avatar,', 'delegate :auto_play_avatar, :audit_probe_setting,')
    flunk('delegate site was not found') if updated == original
    File.binwrite(path, updated)
    output, status = run_check(CATALOG)
    refute status.success?, output
    assert_match(/audit_probe_setting/, output)
  ensure
    File.binwrite(path, original) if original
  end

  def test_rewritten_disposition_fails_consistency
    catalog = YAML.safe_load(File.read(CATALOG), aliases: true)
    entry(catalog, 'user.default_sensitive')['disposition'] = 'candidate_high_risk'
    stats = catalog['meta']['stats']['by_disposition']
    stats['candidate_general'] -= 1
    stats['candidate_high_risk'] += 1
    output, status = run_check(write_catalog(catalog))
    refute status.success?, output
    assert_match(/catalog drift user\.default_sensitive fields: disposition/, output)
  end

  def test_generated_catalog_mismatch_is_detected
    catalog = YAML.safe_load(File.read(CATALOG), aliases: true)
    entry(catalog, 'user.default_privacy')['notes'] += ' catalog drift probe'
    output, status = run_check(write_catalog(catalog))
    refute status.success?, output
    assert_match(/catalog drift user\.default_privacy/, output)
  end

  def test_reviewed_rss_and_group_site_settings
    catalog = YAML.safe_load(File.read(CATALOG), aliases: true)
    discovery = entry(catalog, 'site.external_bridge_rss_activitypub_discovery')
    policy = entry(catalog, 'site.external_bridge_rss_video_policy')
    limit = entry(catalog, 'site.external_bridge_rss_video_max_download_mib')
    creation = entry(catalog, 'site.group_creation_requests')

    assert_equal 'not_writable', discovery['write_policy']
    assert_equal 'admin', discovery['read_policy']
    assert_equal 'verified', discovery['audit_status']
    assert_includes discovery['notes'], 'Schedule.enabled?'
    assert_includes discovery['notes'], 'scanned absence'
    assert_includes discovery['write_sources'].join, 'Form::AdminExternalContentSettings'

    assert_equal 'admin', policy['write_policy']
    assert_equal 'unknown_stored_string_reads_as_remote', policy['configured_vs_effective']
    assert_includes policy['write_sources'].join, 'Form::AdminExternalContentSettings'
    assert_includes policy['write_sources'].join, ':settings, :update?'
    assert_includes policy['notes'], 'does not backfill'
    refute_includes policy['notes'], 'Form::AdminSettings::KEYS'

    assert_equal 'admin', limit['write_policy']
    assert_equal 'out_of_range_reads_as_default_20', limit['configured_vs_effective']
    assert_includes limit['notes'], 'YAML default 20'
    assert_includes limit['normalization'], 'does not write that fallback back'

    assert_equal 'not_writable', creation['write_policy']
    assert_equal 'verified', creation['audit_status']
    assert_includes creation['notes'], 'not on the admin settings form'
    assert_includes creation['notes'], 'feature_disabled'
    assert_includes creation['notes'], 'not_found'
    assert creation['source_refs'].any? { |ref| ref.start_with?('app/services/group_creation_requests/approve_service.rb:') }

    %w[
      enabled shared_quota shared_quota_unlimited per_link_max_uses
      per_link_unlimited_uses per_link_lifetime_seconds per_link_indefinite
    ].each do |suffix|
      item = entry(catalog, "site.group_registration_invites_#{suffix}")
      assert_equal 'admin', item['write_policy'], item['key']
      assert_equal 'site', item['disposition'], item['key']
      assert_equal 'verified', item['audit_status'], item['key']
      assert_includes item['write_sources'].join, 'UpdateSiteDefaults'
      assert_includes item['write_sources'].join, 'authorize_group_admin!'
      assert_includes item['notes'], 'not Form::AdminSettings'
      assert_includes item['notes'], 'server_administrator?'
    end

    uses = entry(catalog, 'site.group_registration_invites_per_link_max_uses')
    lifetime = entry(catalog, 'site.group_registration_invites_per_link_lifetime_seconds')
    assert_equal 'nil_on_read_when_unlimited_uses', uses['configured_vs_effective']
    assert_equal 'nil_on_read_when_indefinite', lifetime['configured_vs_effective']
    assert_includes uses['notes'], 'returns nil when per_link_unlimited_uses is true'

    crop = entry(catalog, 'user.crop_card_images')
    assert_includes crop['notes'], 'Independent of user.crop_images'
    assert_includes crop['read_sources'].join, 'compact timeline cards only'
    assert crop['source_refs'].any? { |ref| ref.start_with?('app/javascript/mastodon/components/status.js:') }
    assert crop['source_refs'].any? { |ref| ref.start_with?('app/javascript/mastodon/components/media_gallery.js:') }
  end

  def test_important_source_refs_name_the_statement
    catalog = YAML.safe_load(File.read(CATALOG), aliases: true)
    catalog['entries'].each do |item|
      key = item['key']
      if key.start_with?('user.notification_emails.')
        assert_source_anchor(item, 'app/services/notify_service.rb', 'settings.notification_emails')
      elsif key.start_with?('user.interactions.')
        child = key.split('.').last
        assert_source_anchor(item, 'app/services/notify_service.rb', "settings.interactions['#{child}']")
      end
    end

    derived = entry(catalog, 'derived.translation_private_content_allowed')
    assert_source_anchor(derived, 'app/lib/translation_service.rb', 'def self.private_content_allowed_for')
    assert_source_anchor(derived, 'app/serializers/initial_state_serializer.rb', 'store[:translation_private_content_allowed]')
    assert_source_anchor(derived, 'app/javascript/mastodon/initial_state.js', 'export const translationPrivateContentAllowed')
    assert_source_anchor(entry(catalog, 'site.site_title'), 'app/models/form/admin_settings.rb', 'KEYS = %i(')

    shifted = entry(catalog, 'user.interactions.must_be_follower').dup
    shifted['source_refs'] = ['app/services/notify_service.rb:78']
    error = assert_raises(Minitest::Assertion) do
      assert_source_anchor(shifted, 'app/services/notify_service.rb', "settings.interactions['must_be_follower']")
    end
    assert_match(/notify_service.rb:78/, error.message)
    cited = File.readlines(File.join(ROOT, 'app/services/notify_service.rb'))[77]
    refute_empty cited.strip
    refute_includes cited, "settings.interactions['must_be_follower']"
  end

  def test_inactive_write_policy_general_fails
    catalog = YAML.safe_load(File.read(CATALOG), aliases: true)
    item = entry(catalog, 'user.notification_emails.followed_message')
    assert_equal 'retained_inactive', item['disposition']
    assert_equal 'not_writable', item['write_policy']
    assert_includes item['write_sources'], 'permitted nested key'
    assert_equal 'unresolved', item['audit_status']
    item['write_policy'] = 'general'
    output, status = run_check(write_catalog(catalog))
    refute status.success?, output
    assert_match(/user\.notification_emails\.followed_message retained_inactive write_policy must be not_writable/, output)
  end

  private

  def entry(catalog, key)
    catalog['entries'].find { |item| item['key'] == key } || flunk("missing #{key}")
  end

  def assert_source_anchor(item, path, snippet)
    ref = Array(item['source_refs']).find { |candidate| candidate.start_with?("#{path}:") }
    flunk("#{item['key']} has no source_ref in #{path}") unless ref
    line_number = ref.split(':').last.to_i
    line = File.readlines(File.join(ROOT, path))[line_number - 1].to_s
    assert_includes line, snippet, "#{item['key']} #{ref} does not contain #{snippet}"
  end

  def write_catalog(catalog)
    file = File.join(Dir.mktmpdir, 'catalog.yml')
    File.write(file, YAML.dump(catalog))
    file
  end

  def run_check(catalog_path)
    Open3.capture2e('ruby', CHECK, '--root', ROOT, '--catalog', catalog_path)
  end
end
