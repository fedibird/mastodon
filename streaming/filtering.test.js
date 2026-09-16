const { describe, it } = require('node:test');
const assert = require('node:assert/strict');

const {
  INLINE_EXCLUDE_SELECTORS,
  searchIndexFromStatus,
  filteredResultsForStatus,
} = require('./filtering');

const compileCachedFilter = (id, keyword, { title = 'spoiler', filter_action = 'warn', whole_word = false, context = ['public'], expires_at = null } = {}) => {
  let expr = keyword.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  if (whole_word) {
    if (/^[\w]/.test(expr)) {
      expr = `\\b${expr}`;
    }

    if (/[\w]$/.test(expr)) {
      expr = `${expr}\\b`;
    }
  }

  return {
    [id]: {
      keywords: [[keyword, whole_word]],
      expires_at,
      regexp: new RegExp(expr, 'i'),
      repr: {
        id,
        title,
        context,
        expires_at,
        filter_action,
      },
    },
  };
};

const applyIfMissing = (payload, cachedFilters) => {
  if (cachedFilters && !payload.filtered) {
    payload.filtered = filteredResultsForStatus(payload, cachedFilters);
  }

  return payload;
};

const statusWith = (overrides = {}) => ({
  spoiler_text: '',
  content: '<p>hello</p>',
  media_attachments: [],
  ...overrides,
});

describe('streaming searchable text', () => {
  it('excludes Fedibird quote/reference/media helper markup', () => {
    assert.deepEqual(INLINE_EXCLUDE_SELECTORS, [
      '.quote-inline',
      '.reference-link-inline',
      '.original-media-link',
    ]);
  });

  it('does not match keywords that only appear in quote-inline markup', () => {
    const cachedFilters = compileCachedFilter('1', 'example.com');
    const status = statusWith({
      content: '<p>hello</p><span class="quote-inline">QT: https://example.com/foo</span>',
    });

    assert.equal(searchIndexFromStatus(status).includes('example.com'), false);
    assert.deepEqual(filteredResultsForStatus(status, cachedFilters), []);
  });

  it('does not match keywords that only appear in reference-link-inline markup', () => {
    const cachedFilters = compileCachedFilter('1', 'example.com');
    const status = statusWith({
      content: '<p>hello</p><span class="reference-link-inline">https://example.com/ref</span>',
    });

    assert.deepEqual(filteredResultsForStatus(status, cachedFilters), []);
  });

  it('does not match keywords that only appear in original-media-link markup', () => {
    const cachedFilters = compileCachedFilter('1', 'cdn.example');
    const status = statusWith({
      content: '<p>hello</p><span class="original-media-link">https://cdn.example/media.png</span>',
    });

    assert.deepEqual(filteredResultsForStatus(status, cachedFilters), []);
  });

  it('matches keywords in the status body', () => {
    const cachedFilters = compileCachedFilter('1', 'example.com', { title: 'links' });
    const status = statusWith({
      content: '<p>hello example.com</p>',
    });
    const results = filteredResultsForStatus(status, cachedFilters);

    assert.equal(results.length, 1);
    assert.equal(results[0].filter.id, '1');
    assert.equal(results[0].filter.title, 'links');
    assert.deepEqual(results[0].filter.context, ['public']);
    assert.ok(results[0].keyword_matches.includes('example.com'));
    assert.equal(results[0].status_matches, null);
    assert.deepEqual(Object.keys(results[0]).sort(), ['filter', 'keyword_matches', 'status_matches']);
  });

  it('matches keywords in spoiler_text', () => {
    const cachedFilters = compileCachedFilter('1', 'spoilerword');
    const status = statusWith({
      spoiler_text: 'this is a spoilerword',
      content: '<p>hello</p>',
    });

    assert.equal(filteredResultsForStatus(status, cachedFilters).length, 1);
  });

  it('matches keywords in poll option titles', () => {
    const cachedFilters = compileCachedFilter('1', 'pineapple');
    const status = statusWith({
      content: '<p>pick one</p>',
      poll: { options: [{ title: 'pineapple' }, { title: 'mango' }] },
    });

    assert.equal(filteredResultsForStatus(status, cachedFilters).length, 1);
  });

  it('matches keywords in media attachment descriptions', () => {
    const cachedFilters = compileCachedFilter('1', 'alttext');
    const status = statusWith({
      content: '<p>photo</p>',
      media_attachments: [{ description: 'an alttext description' }],
    });

    assert.equal(filteredResultsForStatus(status, cachedFilters).length, 1);
  });
});

describe('streaming FilterResult payload', () => {
  it('stores results on filtered and uses warn as a string', () => {
    const cachedFilters = compileCachedFilter('1', 'foo', { filter_action: 'warn' });
    const payload = applyIfMissing(statusWith({ content: '<p>foo</p>' }), cachedFilters);

    assert.equal(payload.filter_results, undefined);
    assert.equal(payload.filtered.length, 1);
    assert.equal(payload.filtered[0].filter.filter_action, 'warn');
    assert.ok(Array.isArray(payload.filtered[0].keyword_matches));
    assert.equal(payload.filtered[0].status_matches, null);
    assert.deepEqual(Object.keys(payload.filtered[0]).sort(), ['filter', 'keyword_matches', 'status_matches']);
  });

  it('uses hide as a string', () => {
    const cachedFilters = compileCachedFilter('2', 'spam', { title: 'spam', filter_action: 'hide' });
    const results = filteredResultsForStatus(statusWith({ content: '<p>spam</p>' }), cachedFilters);

    assert.equal(results[0].filter.filter_action, 'hide');
    assert.ok(Array.isArray(results[0].keyword_matches));
    assert.equal(results[0].status_matches, null);
    assert.deepEqual(Object.keys(results[0]).sort(), ['filter', 'keyword_matches', 'status_matches']);
  });

  it('does not overwrite an existing empty filtered array', () => {
    const cachedFilters = compileCachedFilter('1', 'foo');
    const payload = applyIfMissing({ ...statusWith({ content: '<p>foo</p>' }), filtered: [] }, cachedFilters);

    assert.deepEqual(payload.filtered, []);
  });

  it('does not overwrite server-provided matches', () => {
    const cachedFilters = compileCachedFilter('1', 'foo');
    const existing = [{
      filter: { id: '9', title: 'server', context: ['home'], filter_action: 'warn' },
      keyword_matches: ['already'],
    }];
    const payload = applyIfMissing({ ...statusWith({ content: '<p>foo</p>' }), filtered: existing }, cachedFilters);

    assert.equal(payload.filtered, existing);
  });
});
