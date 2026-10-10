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
    expect(resolveStream({ type: 'hashtag', id: 'ruby', params: { any: ['web'] } }).channels.map(item => item.params.tag)).toEqual(['ruby', 'web']);
    expect(resolveStream({ type: 'hashtag', id: 'ruby', params: { all: ['rails'] } }).mode).toBe('candidate');
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
    expect(classifyStreamStatus(tag, { id: '5', visibility: 'public', tags: [{ name: 'ruby' }, { name: 'web' }] })).toBe('accept');
    expect(classifyStreamStatus(tag, { id: '5', visibility: 'public', tags: [{ name: 'ruby' }, { name: 'spam' }] })).toBe('reject');
    expect(classifyStreamStatus(tag, { id: '5', visibility: 'public', tags: [{ name: 'web' }] })).toBe('accept');
    expect(classifyStreamStatus(tag, { id: '5', visibility: 'public', tags: [{ name: 'ruby' }] })).toBe('accept');
    expect(classifyStreamStatus(tag, { id: '5' })).toBe('unknown');
    expect(classifyStreamStatus(group, { id: '5', tags: [{ name: 'news' }] })).toBe('unknown');
    expect(classifyStreamStatus(group, { id: '5', tags: [{ name: 'news' }] }, { delivered: true })).toBe('accept');
    expect(classifyStreamStatus(group, { id: '5', tags: [{ name: 'other' }] }, { delivered: true })).toBe('reject');
    expect(classifyStreamStatus({ type: 'list', id: '4', params: {} }, { id: '5', visibility: 'public' })).toBe('unknown');
    expect(classifyStreamStatus({ type: 'list', id: '4', params: {} }, { id: '5', visibility: 'public' }, { delivered: true })).toBe('accept');
    expect(classifyStreamStatus({ type: 'public', params: { onlyMedia: true } }, { id: '5', visibility: 'public', media_attachments: [] })).toBe('reject');
    expect(classifyStreamStatus({ type: 'public', params: { onlyMedia: true } }, { id: '5', visibility: 'public' })).toBe('unknown');
    expect(classifyStreamStatus({ type: 'public', params: {} }, { id: '5', visibility: 'private', account: { id: '2' } })).toBe('reject');
    expect(classifyStreamStatus({ type: 'public', params: { withoutBot: true } }, { id: '5', visibility: 'public', account: { id: '2', bot: true }, media_attachments: [] })).toBe('reject');
    expect(classifyStreamStatus({ type: 'account', id: '42', params: {} }, { id: '5', account: { id: '42' } })).toBe('unknown');
  });

  it('keeps the author exception aligned with the saved home and limited shows', () => {
    const home = { type: 'home', params: { shows: { ...shows, reblog: false, reply: false } } };
    const limited = { type: 'limited', params: { shows: { ...shows, reblog: false, reply: false } } };

    expect(classifyStreamStatus(home, { id: '5', visibility: 'public', account: { id: '1' }, reblog: { id: '9' } }, { me: '1' })).toBe('accept');
    expect(classifyStreamStatus(home, { id: '5', visibility: 'public', account: { id: '2' }, reblog: { id: '9' } }, { me: '1' })).toBe('reject');
    expect(classifyStreamStatus(home, { id: '5', visibility: 'public', account: { id: '1' }, in_reply_to_id: '8', in_reply_to_account_id: '3' }, { me: '1' })).toBe('accept');
    expect(classifyStreamStatus(home, { id: '5', visibility: 'public', account: { id: '2' }, in_reply_to_id: '8', in_reply_to_account_id: '3' }, { me: '1' })).toBe('reject');
    expect(classifyStreamStatus(home, { id: '5', visibility: 'public', account: { id: '2' }, in_reply_to_id: '8', in_reply_to_account_id: '1' }, { me: '1' })).toBe('accept');
    expect(classifyStreamStatus(limited, { id: '5', visibility: 'public', account: { id: '1' }, reblog: { id: '9' } }, { me: '1' })).toBe('reject');
    expect(classifyStreamStatus(limited, { id: '5', visibility: 'private', account: { id: '1' }, reblog: { id: '9' } }, { me: '1' })).toBe('accept');
    expect(classifyStreamStatus(limited, { id: '5', visibility: 'private', account: { id: '2' }, reblog: { id: '9' } }, { me: '1' })).toBe('reject');
  });
});
