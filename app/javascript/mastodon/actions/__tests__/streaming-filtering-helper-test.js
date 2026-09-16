const {
  INLINE_EXCLUDE_SELECTORS,
  searchIndexFromStatus,
  filteredResultsForStatus,
} = require('../../../../../streaming/filtering');

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
    expect(INLINE_EXCLUDE_SELECTORS).toEqual([
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

    expect(searchIndexFromStatus(status)).not.toContain('example.com');
    expect(filteredResultsForStatus(status, cachedFilters)).toEqual([]);
  });

  it('does not match keywords that only appear in reference-link-inline markup', () => {
    const cachedFilters = compileCachedFilter('1', 'example.com');
    const status = statusWith({
      content: '<p>hello</p><span class="reference-link-inline">https://example.com/ref</span>',
    });

    expect(filteredResultsForStatus(status, cachedFilters)).toEqual([]);
  });

  it('does not match keywords that only appear in original-media-link markup', () => {
    const cachedFilters = compileCachedFilter('1', 'cdn.example');
    const status = statusWith({
      content: '<p>hello</p><span class="original-media-link">https://cdn.example/media.png</span>',
    });

    expect(filteredResultsForStatus(status, cachedFilters)).toEqual([]);
  });

  it('matches keywords in the status body', () => {
    const cachedFilters = compileCachedFilter('1', 'example.com', { title: 'links' });
    const status = statusWith({
      content: '<p>hello example.com</p>',
    });
    const results = filteredResultsForStatus(status, cachedFilters);

    expect(results).toHaveLength(1);
    expect(results[0].filter.id).toEqual('1');
    expect(results[0].filter.title).toEqual('links');
    expect(results[0].filter.context).toEqual(['public']);
    expect(results[0].keyword_matches).toContain('example.com');
  });

  it('matches keywords in spoiler_text', () => {
    const cachedFilters = compileCachedFilter('1', 'spoilerword');
    const status = statusWith({
      spoiler_text: 'this is a spoilerword',
      content: '<p>hello</p>',
    });

    expect(filteredResultsForStatus(status, cachedFilters)).toHaveLength(1);
  });

  it('matches keywords in poll option titles', () => {
    const cachedFilters = compileCachedFilter('1', 'pineapple');
    const status = statusWith({
      content: '<p>pick one</p>',
      poll: { options: [{ title: 'pineapple' }, { title: 'mango' }] },
    });

    expect(filteredResultsForStatus(status, cachedFilters)).toHaveLength(1);
  });

  it('matches keywords in media attachment descriptions', () => {
    const cachedFilters = compileCachedFilter('1', 'alttext');
    const status = statusWith({
      content: '<p>photo</p>',
      media_attachments: [{ description: 'an alttext description' }],
    });

    expect(filteredResultsForStatus(status, cachedFilters)).toHaveLength(1);
  });
});

describe('streaming FilterResult payload', () => {
  it('stores results on filtered and uses warn as a string', () => {
    const cachedFilters = compileCachedFilter('1', 'foo', { filter_action: 'warn' });
    const payload = applyIfMissing(statusWith({ content: '<p>foo</p>' }), cachedFilters);

    expect(payload.filter_results).toBeUndefined();
    expect(payload.filtered).toHaveLength(1);
    expect(payload.filtered[0].filter.filter_action).toEqual('warn');
  });

  it('uses hide as a string', () => {
    const cachedFilters = compileCachedFilter('2', 'spam', { title: 'spam', filter_action: 'hide' });
    const results = filteredResultsForStatus(statusWith({ content: '<p>spam</p>' }), cachedFilters);

    expect(results[0].filter.filter_action).toEqual('hide');
  });

  it('does not overwrite an existing empty filtered array', () => {
    const cachedFilters = compileCachedFilter('1', 'foo');
    const payload = applyIfMissing({ ...statusWith({ content: '<p>foo</p>' }), filtered: [] }, cachedFilters);

    expect(payload.filtered).toEqual([]);
  });

  it('does not overwrite server-provided matches', () => {
    const cachedFilters = compileCachedFilter('1', 'foo');
    const existing = [{
      filter: { id: '9', title: 'server', context: ['home'], filter_action: 'warn' },
      keyword_matches: ['already'],
    }];
    const payload = applyIfMissing({ ...statusWith({ content: '<p>foo</p>' }), filtered: existing }, cachedFilters);

    expect(payload.filtered).toBe(existing);
  });
});
