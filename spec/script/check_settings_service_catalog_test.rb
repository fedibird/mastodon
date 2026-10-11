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
    assert_match(/entries: 242/, output)
    assert_match(/duplicate keys: 0/, output)
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

  private

  def entry(catalog, key)
    catalog['entries'].find { |item| item['key'] == key } || flunk("missing #{key}")
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
