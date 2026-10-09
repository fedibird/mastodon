import { normalizeSource, sourceIdentityLabel, sourceKey } from '../source';

const home = { type: 'home', params: {} };
const publicSource = { type: 'public', params: {} };

describe('mix source descriptors', () => {
  it('builds a stable key from the type and conditions, not the display title', () => {
    const first = normalizeSource({ type: 'hashtag', id: '#Ruby', title: 'Ruby talk', params: { any: ['Web', 'web'], all: ['Fedibird'] } });
    const second = normalizeSource({ type: 'hashtag', id: 'ruby', title: '別の名前', params: { all: ['fedibird'], any: ['web'] } });

    expect(first.ok).toBe(true);
    expect(sourceKey(first.source)).toBe(sourceKey(second.source));
    expect(sourceKey(first.source)).toBe('v1|hashtag|ruby|all=fedibird&any=web');
    expect(sourceKey(first.source)).not.toContain('Ruby talk');
    expect(sourceIdentityLabel(first.source)).toBe('Ruby talk');
  });

  it('keeps the same timeline type distinct when conditions differ', () => {
    const plain = sourceKey({ type: 'hashtag', id: 'ruby', params: {} });
    const tagged = sourceKey({ type: 'hashtag', id: 'ruby', params: { none: ['spam'] } });
    const media = sourceKey({ type: 'public', params: { onlyMedia: true } });
    const bots = sourceKey({ type: 'public', params: { withoutBot: true } });
    const replies = sourceKey({ type: 'account', id: '42', params: { withReplies: true } });
    const boosts = sourceKey({ type: 'account', id: '42', params: { withoutReblogs: true } });

    expect(plain).not.toBe(tagged);
    expect(sourceKey(publicSource)).not.toBe(media);
    expect(sourceKey(publicSource)).not.toBe(bots);
    expect(sourceKey({ type: 'account', id: '42', params: {} })).not.toBe(replies);
    expect(replies).not.toBe(boosts);
    expect(sourceKey(home)).toBe('v1|home|-|shows=direct:1,limited:1,personal:1,private:1,reblog:1,reply:1');
    expect(sourceKey({ type: 'home', title: '自宅', params: { shows: { reply: false } } })).toBe('v1|home|-|shows=direct:1,limited:1,personal:1,private:1,reblog:1,reply:0');
  });

  it('stores a complete home show snapshot instead of following the home column', () => {
    const untouched = normalizeSource({ type: 'home', params: {} });
    const hiddenReplies = normalizeSource({ type: 'home', params: { shows: { reply: false, reblog: true } } });

    expect(untouched.source.params.shows).toEqual({
      reblog: true,
      reply: true,
      private: true,
      limited: true,
      direct: true,
      personal: true,
    });
    expect(hiddenReplies.source.params.shows).toEqual({
      reblog: true,
      reply: false,
      private: true,
      limited: true,
      direct: true,
      personal: true,
    });
    expect(sourceKey(untouched.source)).not.toBe(sourceKey(hiddenReplies.source));
    expect(JSON.stringify(untouched.source)).not.toContain('settings');
  });

  it('rejects empty, unknown, conflicting, and URL endpoint sources', () => {
    expect(normalizeSource({ type: 'account', id: '' }).error).toBe('id_blank');
    expect(normalizeSource({ type: 'account', id: 'https://example.com/users/a' }).error).toBe('id_invalid');
    expect(normalizeSource({ type: 'domain', domain: 'https://example.com/api/v1/timelines/public' }).error).toBe('url_rejected');
    expect(normalizeSource({ type: 'home', endpoint: 'https://example.com/api/v1/timelines/home' }).error).toBe('url_rejected');
    expect(normalizeSource({ type: 'public', params: { url: '/api/v1/timelines/public' } }).error).toBe('url_rejected');
    expect(normalizeSource({ type: 'nope' }).error).toBe('type_unknown');
    expect(normalizeSource({ type: 'public', params: { onlyMedia: true, withoutMedia: true } }).error).toBe('media_conflict');
    expect(normalizeSource({ type: 'list', id: '7', params: { onlyMedia: true } }).error).toBe('param_unsupported');
    expect(sourceKey({ type: 'home', endpoint: 'https://evil.example' })).toBeNull();
  });

  it('drops post bodies and keeps only the descriptor', () => {
    const normalized = normalizeSource({
      type: 'list',
      id: '15',
      title: 'Friends',
      statuses: [{ id: '9', content: 'secret' }],
      params: {},
    });

    expect(normalized.ok).toBe(true);
    expect(normalized.source).toEqual({
      type: 'list',
      id: '15',
      title: 'Friends',
      params: {},
    });
    expect(JSON.stringify(normalized.source)).not.toContain('secret');
  });

  it('normalizes group tags, domain names, and account reply conditions', () => {
    const group = normalizeSource({ type: 'group', id: '8', params: { tagged: '#News', onlyMedia: false } });
    const domain = normalizeSource({ type: 'domain', domain: 'Example.COM.', params: { withoutBot: true } });
    const account = normalizeSource({ type: 'account', id: '99', title: 'ada@example.com', params: { withReplies: false, withoutReblogs: true, tagged: 'photos' } });

    expect(group.source.params).toEqual({ tagged: 'news' });
    expect(domain.error).toBe('domain_invalid');
    expect(normalizeSource({ type: 'domain', domain: 'example.com', params: { withoutBot: true } }).source).toEqual({
      type: 'domain',
      domain: 'example.com',
      params: { withoutBot: true },
    });
    expect(account.source.params).toEqual({ withoutReblogs: true, tagged: 'photos' });
    expect(sourceKey(account.source)).toBe('v1|account|99|tagged=photos&withoutReblogs=1');
  });
});
