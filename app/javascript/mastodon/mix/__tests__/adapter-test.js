import { classifyFetchError, resolveSource } from '../adapter';

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
  });
});
