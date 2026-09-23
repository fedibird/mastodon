import { fromJS, List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { COMPOSE_DIRECT, COMPOSE_EDIT_CANCEL, COMPOSE_MEDIA_ORDER_CHANGE, COMPOSE_MENTION, COMPOSE_SET_STATUS, COMPOSE_VISIBILITY_CHANGE } from '../../actions/compose';
import compose from '../compose';

describe('COMPOSE_SET_STATUS', () => {
  const base = compose(undefined, { type: '@@INIT' })
    .set('searchability', 'private')
    .set('circle_id', 'circle-1')
    .set('quote_from', 'quoted-1')
    .set('quote_from_url', 'https://example.test/quoted')
    .set('references', ImmutableSet(['ref-1']))
    .set('context_references', ImmutableSet(['ctx-1']))
    .set('scheduled', '2026-01-01 00:00')
    .set('expires', '2026-02-01 00:00')
    .set('expires_action', 'delete')
    .set('scheduled_status_id', 'sched-1')
    .set('prohibited_visibilities', ImmutableSet(['direct']))
    .set('prohibited_words', ImmutableSet(['nope']));

  const action = {
    type: COMPOSE_SET_STATUS,
    text: 'raw body',
    spoiler_text: 'raw spoiler',
    status: fromJS({
      id: 's1',
      visibility: 'private',
      sensitive: true,
      language: 'ja',
      in_reply_to_id: 'parent-1',
      media_attachments: [
        { id: 'm1', description: 'one', meta: { focus: { x: 0.1, y: -0.2 } } },
        { id: 'm2', description: 'two' },
      ],
      poll: {
        options: [{ title: 'Yes' }, { title: 'No' }],
        multiple: true,
        expires_at: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
      },
    }),
  };

  it('loads the editing fields from the status and raw source', () => {
    const next = compose(base, action);

    expect(next.get('id')).toEqual('s1');
    expect(next.get('text')).toEqual('raw body');
    expect(next.get('spoiler_text')).toEqual('raw spoiler');
    expect(next.get('spoiler')).toBe(true);
    expect(next.get('sensitive')).toBe(true);
    expect(next.get('language')).toEqual('ja');
    expect(next.getIn(['media_attachments', 0, 'id'])).toEqual('m1');
    expect(next.getIn(['media_attachments', 1, 'id'])).toEqual('m2');
    expect(next.getIn(['poll', 'options']).toJS()).toEqual(['Yes', 'No']);
    expect(next.getIn(['poll', 'multiple'])).toBe(true);
    expect(next.get('in_reply_to')).toEqual('parent-1');
    expect(next.get('privacy')).toEqual('private');
  });

  it('does not clear Fedibird-only compose fields', () => {
    const next = compose(base, action);

    expect(next.get('searchability')).toEqual('private');
    expect(next.get('circle_id')).toEqual('circle-1');
    expect(next.get('quote_from')).toEqual('quoted-1');
    expect(next.get('quote_from_url')).toEqual('https://example.test/quoted');
    expect(next.get('references').includes('ref-1')).toBe(true);
    expect(next.get('context_references').includes('ctx-1')).toBe(true);
    expect(next.get('scheduled')).toEqual('2026-01-01 00:00');
    expect(next.get('expires')).toEqual('2026-02-01 00:00');
    expect(next.get('expires_action')).toEqual('delete');
    expect(next.get('scheduled_status_id')).toEqual('sched-1');
    expect(next.get('prohibited_visibilities').includes('direct')).toBe(true);
    expect(next.get('prohibited_words').includes('nope')).toBe(true);
  });

  it('does not copy quote or references from the status being edited', () => {
    const next = compose(base, {
      ...action,
      status: action.status.merge(fromJS({
        quote: { id: 'other-quote', url: 'https://example.test/other' },
        status_reference_ids: ['other-ref'],
        searchability: 'public',
        circle_id: 'other-circle',
      })),
    });

    expect(next.get('quote_from')).toEqual('quoted-1');
    expect(next.get('references').includes('other-ref')).toBe(false);
    expect(next.get('searchability')).toEqual('private');
    expect(next.get('circle_id')).toEqual('circle-1');
  });

  it('clears editing state on cancel', () => {
    const editing = compose(base, action);
    const next = compose(editing, { type: COMPOSE_EDIT_CANCEL });

    expect(next.get('id')).toBeNull();
    expect(next.get('text')).toEqual('');
    expect(next.get('spoiler_text')).toEqual('');
    expect(next.get('media_attachments').size).toEqual(0);
    expect(next.get('poll')).toBeNull();
    expect(next.get('language')).toBeNull();
  });

  it('keeps media order and ignores visibility changes while editing', () => {
    const editing = compose(base, action);
    const reordered = compose(editing, { type: COMPOSE_MEDIA_ORDER_CHANGE, id: 'm2', direction: -1 });

    expect(reordered.get('media_attachments').map(item => item.get('id')).toJS()).toEqual(['m2', 'm1']);

    const unchanged = compose(reordered, { type: COMPOSE_VISIBILITY_CHANGE, value: 'public' });
    expect(unchanged.get('privacy')).toEqual('private');
  });

  it('keeps the edit when inserting a mention or direct', () => {
    const editing = compose(base, action);
    const account = fromJS({ acct: 'alice' });
    const mentioned = compose(editing, { type: COMPOSE_MENTION, account });
    const directed = compose(editing, { type: COMPOSE_DIRECT, account });

    expect(mentioned.get('id')).toEqual('s1');
    expect(mentioned.get('text')).toEqual('raw body @alice ');
    expect(mentioned.get('privacy')).toEqual('private');
    expect(directed.get('id')).toEqual('s1');
    expect(directed.get('privacy')).toEqual('private');
    expect(directed.get('text')).toEqual('raw body @alice ');
  });

  it('clears a previous draft poll when the status has none', () => {
    const withPoll = base.set('poll', ImmutableMap({ options: ImmutableList(['a', 'b']), multiple: false, expires_in: 3600 }));
    const next = compose(withPoll, {
      ...action,
      status: action.status.delete('poll'),
    });

    expect(next.get('poll')).toBeNull();
  });
});
