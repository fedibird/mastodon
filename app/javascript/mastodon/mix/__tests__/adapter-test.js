import { classifyFetchError, normalizePage, resolveRequest, resolveSource } from '../adapter';

describe('mix source adapter', () => {
  it('selects a known endpoint and encodes ids', () => {
    const home = resolveSource({ type: 'home', params: { shows: { direct: false, reply: true, reblog: true, private: true, limited: true, personal: true } } });
    const tag = resolveSource({ type: 'hashtag', id: 'ruby on rails', params: { any: ['web'] } });
    const account = resolveSource({ type: 'account', id: '42', params: { withReplies: true, withoutReblogs: true } });

    expect(home.path).toBe('/api/v1/timelines/home');
    expect(home.params.visibilities).not.toContain('direct');
    expect(home.params.visibilities).toContain('public');
    expect(tag.ok).toBe(false);
    expect(resolveSource({ type: 'hashtag', id: 'ruby', params: { any: ['web'] } })).toMatchObject({
      path: '/api/v1/timelines/tag/ruby',
      params: { any: ['web'] },
    });
    expect(account).toMatchObject({
      path: '/api/v1/accounts/42/statuses',
      params: { exclude_replies: false, exclude_reblogs: true },
    });
    expect(resolveSource({ type: 'home', endpoint: 'https://example.invalid/api' }).ok).toBe(false);
  });

  it('classifies permission and server failures separately', () => {
    expect(classifyFetchError({ response: { status: 403 } })).toBe('forbidden');
    expect(classifyFetchError({ response: { status: 404 } })).toBe('not_found');
    expect(classifyFetchError({ response: { status: 500 } })).toBe('server');
    expect(classifyFetchError(new Error('offline'))).toBe('unavailable');
    expect(classifyFetchError({ response: { status: 429, headers: { 'retry-after': '5' } } })).toBe('rate_limit');
  });

  it('normalizes compact pages, link cursors, and partial responses without using a raw URL', () => {
    const compact = normalizePage({
      status: 200,
      data: {
        statuses: [{ id: '500', filtered: [{ filter: '1' }] }, { id: '400' }],
        accounts: [{ id: '2' }],
        referenced_statuses: [{ id: '10' }],
      },
      nextUri: '/api/v1/timelines/home?max_id=400',
    });
    const partial = normalizePage({
      status: 206,
      data: [{ id: '500' }, { id: '400' }],
      nextUri: 'https://evil.example/api?max_id=1',
    });
    const unordered = normalizePage({
      status: 200,
      data: [{ id: '400' }, { id: '500' }],
    });

    expect(compact).toMatchObject({
      ok: true,
      compact: true,
      ids: ['500', '400'],
      cursor: '400',
      hasMore: true,
      frontier: '400',
      filterResults: { '500': [{ filter: '1' }] },
    });
    expect(compact.statuses[0].filtered).toBeUndefined();
    expect(partial.ok).toBe(false);
    expect(partial.error).toBe('foreign_link');
    expect(unordered).toMatchObject({ ok: false, error: 'order' });
    expect(resolveRequest({
      type: 'home',
      params: { shows: { direct: true, personal: true, private: true, limited: true, reblog: true, reply: true } },
    }, null, { hideDirectFromTimeline: true, hidePersonalFromTimeline: true, enableLimitedTimeline: true }).params.visibilities).toEqual(['public', 'unlisted', 'private', 'limited']);
  });
});
