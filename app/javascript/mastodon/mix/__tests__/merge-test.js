import { buildMixView, nextFetchKeys, safePrefix } from '../merge';

const source = (key, ids, extra = {}) => ({
  key,
  ids,
  hasMore: false,
  loaded: true,
  loading: false,
  error: null,
  source: extra.descriptor || { type: 'public', params: {} },
  ...extra,
});

describe('mix merge', () => {
  it('merges two and three sources in descending id order', () => {
    const two = safePrefix([
      source('a', ['500', '300']),
      source('b', ['400', '200']),
    ]);
    const three = safePrefix([
      source('a', ['500', '300']),
      source('b', ['400', '200']),
      source('c', ['450', '250']),
    ]);

    expect(two.ids).toEqual(['500', '450', '400', '300', '250', '200'].filter(id => ['500', '400', '300', '200'].indexOf(id) !== -1));
    expect(two.ids).toEqual(['500', '400', '300', '200']);
    expect(three.ids).toEqual(['500', '450', '400', '300', '250', '200']);
    expect(three.orderGuaranteed).toBe(true);
  });

  it('keeps one copy of a repeated status id and both distinct boosts', () => {
    const view = buildMixView([
      source('home', ['500', '400'], { descriptor: { type: 'home', params: { shows: { reblog: true, reply: true } } } }),
      source('public', ['400', '300']),
    ], {
      '500': { id: '500', reblog: { id: '100' }, account: '2' },
      '400': { id: '400', reblog: null, account: '3' },
      '300': { id: '300', reblog: { id: '100' }, account: '4' },
    });

    expect(view.ids).toEqual(['500', '400', '300']);
    expect(view.sourceKeysById['400']).toEqual(['home', 'public']);
    expect(view.ids.indexOf('500')).not.toBe(view.ids.indexOf('300'));
  });

  it('holds back ids that an unfinished denser source might still insert', () => {
    const blocked = safePrefix([
      source('dense', ['500', '400', '300'], { hasMore: true }),
      source('sparse', ['450', '200'], { hasMore: true }),
    ]);

    expect(blocked.ids).toEqual(['500', '450', '400', '300']);
    expect(blocked.orderGuaranteed).toBe(true);

    const extended = safePrefix([
      source('dense', ['500', '400', '300', '250'], { hasMore: true }),
      source('sparse', ['450', '200'], { hasMore: false }),
    ]);

    expect(extended.ids).toEqual(['500', '450', '400', '300', '250']);
  });

  it('keeps an exhausted source from blocking an empty one', () => {
    const view = safePrefix([
      source('filled', ['500', '400']),
      source('empty', []),
    ]);

    expect(view.ids).toEqual(['500', '400']);
    expect(view.orderGuaranteed).toBe(true);

    const oneOpen = safePrefix([
      source('done', ['500', '400'], { hasMore: false }),
      source('open', ['350'], { hasMore: true }),
    ]);

    expect(oneOpen.ids).toEqual(['500', '400', '350']);
  });

  it('does not claim a complete order when a source failed, and drops forbidden ids', () => {
    const failed = safePrefix([
      source('home', ['500', '400']),
      source('list', [], { error: 'server', hasMore: true }),
    ]);
    const forbidden = buildMixView([
      source('home', [], { error: 'forbidden', descriptor: { type: 'home', title: 'Home', params: {} } }),
      source('public', ['500']),
    ], {
      '500': { id: '500', account: '2' },
    });

    expect(failed.ids).toEqual(['500', '400']);
    expect(failed.orderGuaranteed).toBe(false);
    expect(safePrefix([
      source('home', ['500', '400']),
      source('list', ['450'], { error: 'server', hasMore: true }),
    ]).ids).toEqual(['500', '450', '400']);
    expect(forbidden.ids).toEqual(['500']);
    expect(forbidden.orderGuaranteed).toBe(false);
    expect(forbidden.errors).toEqual([{ key: 'home', error: 'forbidden', label: 'Home', retryAt: null }]);
  });

  it('uses the home snapshot to hide replies without reading home settings', () => {
    const view = buildMixView([
      source('home', ['500', '400'], {
        descriptor: { type: 'home', params: { shows: { reply: false, reblog: true, private: true, direct: true, limited: true, personal: true } } },
      }),
    ], {
      '500': { id: '500', visibility: 'public', in_reply_to_id: '10', in_reply_to_account_id: '9', account: '2' },
      '400': { id: '400', visibility: 'public', in_reply_to_id: null, account: '2' },
    }, { me: '1' });

    expect(view.ids).toEqual(['400']);

    const ownReply = buildMixView([
      source('home', ['500'], {
        descriptor: { type: 'home', params: { shows: { reply: false, reblog: false, private: true, direct: true, limited: true, personal: true } } },
      }),
    ], {
      '500': { id: '500', visibility: 'public', reblog: { id: '9' }, account: '1' },
    }, { me: '1' });

    expect(ownReply.ids).toEqual(['500']);
  });

  it('hides a status only when every source context would hide it', () => {
    const filters = [{ id: 'f1', filter_action: 'hide', context: ['home'] }];
    const status = { id: '500', filtered: [{ filter: 'f1' }], account: '2' };
    const homeOnly = buildMixView([
      source('home', ['500'], {
        descriptor: { type: 'home', params: { shows: { reply: true, reblog: true } } },
        filterResults: { '500': [{ filter: 'f1' }] },
      }),
    ], { '500': status }, { filters, contexts: { home: 'home' } });
    const both = buildMixView([
      source('home', ['500'], {
        descriptor: { type: 'home', params: { shows: { reply: true, reblog: true } } },
        filterResults: { '500': [{ filter: 'f1' }] },
      }),
      source('public', ['500'], {
        descriptor: { type: 'public', params: {} },
        filterResults: { '500': [] },
      }),
    ], { '500': { ...status, filtered: [{ filter: 'other' }] } }, { filters, contexts: { home: 'home', public: 'public' } });
    const warned = buildMixView([
      source('public', ['500'], {
        descriptor: { type: 'public', params: {} },
        filterResults: { '500': [{ filter: 'f2' }] },
      }),
    ], { '500': status }, {
      filters: [{ id: 'f2', filter_action: 'warn', title: 'Spoilers', context: ['public'] }],
      contexts: { public: 'public' },
    });

    expect(homeOnly.ids).toEqual([]);
    expect(both.ids).toEqual(['500']);
    expect(both.contextById['500']).toBe('public');
    expect(both.warningsById['500']).toEqual([]);
    expect(both.sourceKeysById['500']).toEqual(['public']);
    expect(warned.ids).toEqual(['500']);
    expect(warned.warningsById['500']).toEqual(['Spoilers']);

    const removed = buildMixView([
      source('home', ['500'], {
        descriptor: { type: 'home', params: { shows: { reply: true, reblog: true } } },
        filterResults: { '500': [{ filter: 'f1' }] },
      }),
    ], { '500': status }, { filters: [], contexts: { home: 'home' } });

    expect(removed.ids).toEqual(['500']);
  });

  it('shows posts from a partial page without calling the source finished', () => {
    const view = safePrefix([
      source('public', ['500', '400'], { hasMore: true, partial: true, frontier: null }),
      source('list', ['450'], { hasMore: false }),
    ]);

    expect(view.ids).toEqual(['500', '450', '400']);
    expect(view.orderGuaranteed).toBe(false);
    expect(safePrefix([
      source('home', ['100', '80', '70', '60'], { hasMore: false, partial: false, frontier: '60', gap: true }),
    ]).orderGuaranteed).toBe(false);

    const held = buildMixView([
      source('public', ['500'], {
        hasMore: true,
        partial: true,
        suspended: true,
        frontier: null,
        descriptor: { type: 'public', params: {} },
      }),
    ], {
      '500': { id: '500', account: '2' },
    }, { contexts: { public: 'public' } });

    expect(held.ids).toEqual(['500']);
    expect(held.orderGuaranteed).toBe(false);
    expect(held.hasMore).toBe(false);
    expect(held.suspended).toEqual([{ key: 'public', label: 'public' }]);
  });

  it('fetches the sources that limit the prefix and stops at the budget', () => {
    const initial = [
      source('a', [], { loaded: false, hasMore: true }),
      source('b', [], { loaded: false, hasMore: true }),
      source('c', [], { loaded: false, hasMore: true }),
    ];

    expect(nextFetchKeys(initial, { budget: 2, target: 20 })).toEqual(['a', 'b']);

    const skewed = [
      source('dense', ['500', '400', '300'], { hasMore: true }),
      source('sparse', ['450', '200'], { hasMore: true }),
    ];

    expect(nextFetchKeys(skewed, { budget: 8, target: 20 })).toEqual(['dense']);
    expect(nextFetchKeys([
      source('partial', ['500'], { hasMore: true, partial: true, suspended: true, frontier: null }),
    ], { budget: 8, target: 20 })).toEqual([]);
    expect(nextFetchKeys([
      source('partial', ['500'], { hasMore: true, partial: true, suspended: false, frontier: null }),
    ], { budget: 8, target: 20 })).toEqual(['partial']);
    expect(nextFetchKeys(skewed, { budget: 0, target: 20 })).toEqual([]);
    expect(nextFetchKeys([
      source('done', ['500', '400', '300', '200']),
      source('also', ['450', '250']),
    ], { budget: 8, target: 2 })).toEqual([]);
  });

  it('keeps only visible sources in sourceKeysById', () => {
    const status = { id: '500', visibility: 'public', account: '2', reblog: null };
    const filters = [
      { id: 'hide-home', filter_action: 'hide', title: 'Home hide', context: ['home'] },
      { id: 'warn-tag', filter_action: 'warn', title: 'Spoilers', context: ['public'] },
    ];
    const contexts = { home: 'home', tag: 'public', news: 'public' };
    const view = buildMixView([
      source('home', ['500'], {
        descriptor: { type: 'home', params: { shows: { reply: true, reblog: true } } },
        filterResults: { '500': [{ filter: 'hide-home' }] },
      }),
      source('tag', ['500'], {
        descriptor: { type: 'hashtag', id: 'fediverse', params: {} },
        filterResults: { '500': [{ filter: 'warn-tag' }] },
      }),
      source('news', ['500'], {
        descriptor: { type: 'list', id: '4', title: 'News', params: {} },
        filterResults: { '500': [] },
      }),
    ], { '500': status }, { filters, contexts });

    expect(view.ids).toEqual(['500']);
    expect(view.sourceKeysById['500']).toEqual(['tag', 'news']);
    expect(view.sourceWarningsById['500']).toEqual({ tag: ['Spoilers'], news: [] });
    expect(view.warningsById['500']).toEqual(['Spoilers']);
    expect(view.contextById['500']).toBe('public');

    const repliesOff = buildMixView([
      source('home', ['500'], { descriptor: { type: 'home', params: { shows: { reply: false, reblog: true } } } }),
    ], { '500': { ...status, account: '3', in_reply_to_id: '1', in_reply_to_account_id: '9' } }, { me: '2', contexts });

    expect(repliesOff.ids).toEqual([]);

    const removed = buildMixView([
      source('news', ['500'], { descriptor: { type: 'list', id: '4', params: {} } }),
    ], { '500': status }, { tombstones: ['500'], contexts });

    expect(removed.ids).toEqual([]);
    expect(removed.sourceKeysById['500']).toBeUndefined();
  });
});
