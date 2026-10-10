jest.mock('../../initial_state', () => ({
  get enableLimitedTimeline () {
    return true;
  },
  get hideDirectFromTimeline () {
    return false;
  },
  get hidePersonalFromTimeline () {
    return false;
  },
}));

import { classifyStreamStatus, resolveStream } from '../stream_adapters';

const shows = { reblog: true, reply: true, private: true, limited: true, direct: true, personal: true };

describe('mix streaming adapters', () => {
  it('chooses a channel when the source can be subscribed exactly', () => {
    expect(resolveStream({ type: 'public', params: { withoutBot: true } })).toMatchObject({
      mode: 'supported',
      channel: 'public:nobot',
    });
    expect(resolveStream({ type: 'remote', params: { onlyMedia: true } })).toMatchObject({
      mode: 'supported',
      channel: 'public:remote:bot:media',
    });
    expect(resolveStream({ type: 'domain', domain: 'example.com', params: {} })).toMatchObject({
      mode: 'supported',
      channel: 'public:domain:bot',
      params: { domain: 'example.com' },
    });
    expect(resolveStream({ type: 'list', id: '4', params: {} })).toMatchObject({
      mode: 'supported',
      channel: 'list',
      params: { list: '4' },
    });
    expect(resolveStream({ type: 'group', id: '9', params: { tagged: 'news' } })).toMatchObject({
      mode: 'supported',
      channel: 'group',
      params: { id: '9', tagged: 'news' },
    });
    expect(resolveStream({ type: 'hashtag', id: 'ruby', params: {} })).toMatchObject({
      mode: 'supported',
      channel: 'hashtag',
      params: { tag: 'ruby' },
    });
    expect(resolveStream({ type: 'hashtag', id: 'ruby', params: { any: ['web'] } }).mode).toBe('candidate');
    expect(resolveStream({ type: 'home', params: { shows } })).toMatchObject({ mode: 'candidate', channel: 'user' });
    expect(resolveStream({ type: 'account', id: '42', params: {} })).toMatchObject({ mode: 'rest_only' });
  });

  it('applies saved visibility, tag, media, and bot conditions', () => {
    const home = { type: 'home', params: { shows: { ...shows, direct: false, reblog: false } } };
    const tag = { type: 'hashtag', id: 'ruby', params: { any: ['web'], none: ['spam'] } };
    const group = { type: 'group', id: '9', params: { tagged: 'news' } };

    expect(classifyStreamStatus(home, { id: '5', visibility: 'direct', account: { id: '2' } }, { me: '1' })).toBe('reject');
    expect(classifyStreamStatus(home, { id: '5', visibility: 'public', reblog: { id: '1' }, account: { id: '2' } }, { me: '1' })).toBe('reject');
    expect(classifyStreamStatus({ type: 'limited', params: { shows } }, { id: '5', visibility: 'public', account: { id: '2' } }, { me: '1' })).toBe('reject');
    expect(classifyStreamStatus({ type: 'personal', params: { shows: { reply: true } } }, { id: '5', visibility: 'personal', account: { id: '2' } }, { me: '1' })).toBe('accept');
    expect(classifyStreamStatus(tag, { id: '5', tags: [{ name: 'ruby' }, { name: 'web' }] })).toBe('accept');
    expect(classifyStreamStatus(tag, { id: '5', tags: [{ name: 'ruby' }, { name: 'spam' }] })).toBe('reject');
    expect(classifyStreamStatus(tag, { id: '5' })).toBe('unknown');
    expect(classifyStreamStatus(group, { id: '5', tags: [{ name: 'news' }] })).toBe('accept');
    expect(classifyStreamStatus(group, { id: '5', tags: [{ name: 'other' }] })).toBe('reject');
    expect(classifyStreamStatus({ type: 'public', params: { onlyMedia: true } }, { id: '5', media_attachments: [] })).toBe('reject');
    expect(classifyStreamStatus({ type: 'public', params: { withoutBot: true } }, { id: '5', account: { id: '2', bot: true }, media_attachments: [] })).toBe('reject');
    expect(classifyStreamStatus({ type: 'account', id: '42', params: {} }, { id: '5', account: { id: '42' } })).toBe('unknown');
  });
});
