import fs from 'fs';
import path from 'path';

describe('streaming custom-filter query', () => {
  const source = fs.readFileSync(path.join(__dirname, '../../../../../streaming/index.js'), 'utf8');

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
});
