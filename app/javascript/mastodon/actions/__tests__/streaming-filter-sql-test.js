import fs from 'fs';
import path from 'path';

describe('streaming custom-filter query', () => {
  const source = fs.readFileSync(path.join(__dirname, '../../../../../streaming/index.js'), 'utf8');
  const webUiStreaming = fs.readFileSync(path.join(__dirname, '../streaming.js'), 'utf8');

  it('scopes expiration checks to the current account', () => {
    expect(source).toContain(
      'WHERE filter.account_id = $1 AND (filter.expires_at IS NULL OR filter.expires_at > NOW())',
    );
    expect(source).not.toMatch(
      /WHERE filter\.account_id = \$1 AND filter\.expires_at IS NULL OR filter\.expires_at > NOW\(\)/,
    );
  });

  it('emits warn/hide strings for filter_action', () => {
    expect(source).toMatch(/filter_action: \['warn', 'hide'\]\[row\.filter_action\]/);
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
    expect(source).toContain("event === 'filters_changed'");
    expect(source).toContain('req.cachedFilters = null');
  });

  it('does not restore WebUI filters_changed fetching', () => {
    expect(webUiStreaming).not.toMatch(/filters_changed/);
    expect(webUiStreaming).not.toMatch(/fetchNotificationFilters/);
  });
});
