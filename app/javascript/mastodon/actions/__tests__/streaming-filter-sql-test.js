import fs from 'fs';
import path from 'path';

describe('streaming custom-filter query', () => {
  const source = fs.readFileSync(path.join(__dirname, '../../../../../streaming/index.js'), 'utf8');
  const filtering = fs.readFileSync(path.join(__dirname, '../../../../../streaming/filtering.js'), 'utf8');
  const webUiStreaming = fs.readFileSync(path.join(__dirname, '../streaming.js'), 'utf8');

  it('scopes expiration checks to the current account', () => {
    expect(source).toContain(
      'WHERE filter.account_id = $1 AND (filter.expires_at IS NULL OR filter.expires_at > NOW())',
    );
    expect(source).not.toMatch(
      /WHERE filter\.account_id = \$1 AND filter\.expires_at IS NULL OR filter\.expires_at > NOW\(\)/,
    );
  });

  it('loads keyword-less filters with a LEFT JOIN and a CustomFilterStatus query', () => {
    expect(source).toContain('LEFT JOIN custom_filter_keywords keyword ON keyword.custom_filter_id = filter.id');
    expect(source).toContain('FROM custom_filter_statuses filtered_status JOIN custom_filters filter ON filtered_status.custom_filter_id = filter.id');
    expect(source).toContain('req.cachedFilters = buildCachedFilters(keywordRows, statusRows)');
  });

  it('emits warn/hide strings for filter_action', () => {
    expect(filtering).toMatch(/filter_action: \['warn', 'hide'\]\[row\.filter_action\]/);
  });

  it('stores FilterResult on the canonical filtered field', () => {
    expect(source).toContain('payload.filtered = filteredResultsForStatus(unpackedPayload, req.cachedFilters)');
    expect(source).toContain('if (!unpackedPayload.filtered && !req.cachedFilters)');
    expect(source).toContain('if (req.cachedFilters && !unpackedPayload.filtered)');
  });

  it('does not generate the legacy filter_results field', () => {
    expect(source).not.toMatch(/filter_results/);
  });

  it('invalidates the Node filter cache on filters_changed', () => {
    expect(source).toMatch(/event === 'filters_changed'/);
    expect(source).toContain('req.cachedFilters = null');
  });

  it('does not restore WebUI filters_changed fetching', () => {
    expect(webUiStreaming).not.toMatch(/filters_changed/);
    expect(webUiStreaming).not.toMatch(/fetchNotificationFilters/);
  });

  it('still transmits hide-filtered statuses', () => {
    expect(source).toContain('payload.filtered = filteredResultsForStatus(unpackedPayload, req.cachedFilters)');
    expect(source).toMatch(/transmit\(\);/);
    expect(source).not.toMatch(/filter_action === 'hide'[\s\S]{0,80}return;/);
  });

  it('strips the internal searchable text at the transmit boundary', () => {
    expect(source).toContain('stripStreamingSearchableText(payload)');
    expect(source).toMatch(/const transmit = \(\) => \{[\s\S]*stripStreamingSearchableText\(payload\);[\s\S]*JSON\.stringify\(payload\)/);
    expect(filtering).toContain("const STREAMING_SEARCHABLE_TEXT_KEY = '_fedibird_searchable_text'");
    expect(filtering).toContain('typeof status[STREAMING_SEARCHABLE_TEXT_KEY] === \'string\'');
    expect(filtering).not.toMatch(/querySelectorAll\('a'\)/);
  });
});
