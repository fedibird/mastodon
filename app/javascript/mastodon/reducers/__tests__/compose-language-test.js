import { fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { COMPOSE_LANGUAGE_CHANGE, COMPOSE_QUOTE, COMPOSE_REPLY, COMPOSE_REPLY_CANCEL, COMPOSE_RESET, COMPOSE_SUBMIT_SUCCESS } from '../../actions/compose';
import { LANGUAGE_USE } from '../../actions/languages';
import { STORE_HYDRATE } from '../../actions/store';
import { REDRAFT } from '../../actions/statuses';
import compose from '../compose';
import settings from '../settings';

const hydrated = () => compose(undefined, {
  type: STORE_HYDRATE,
  state: fromJS({
    compose: {
      default_language: 'ja',
      default_privacy: 'public',
    },
  }),
});

const replyStatus = (extra = {}) => fromJS({
  id: 's1',
  language: 'en',
  visibility: 'public',
  spoiler_text: '',
  mentions: [],
  account: { id: '2', acct: 'bob' },
  ...extra,
});

describe('compose language', () => {
  it('starts a new compose in the hydrated default language', () => {
    const state = hydrated();

    expect(state.get('default_language')).toEqual('ja');
    expect(state.get('language')).toEqual('ja');
  });

  it('returns to the default language after submit and reset', () => {
    const drafting = hydrated().set('language', 'en').set('text', 'Hello');

    expect(compose(drafting, { type: COMPOSE_SUBMIT_SUCCESS }).get('language')).toEqual('ja');
    expect(compose(drafting, { type: COMPOSE_RESET }).get('language')).toEqual('ja');
    expect(compose(drafting, { type: COMPOSE_REPLY_CANCEL }).get('language')).toEqual('ja');
  });

  it('marks a language change as a dirty edit and rotates the idempotency key', () => {
    const state = hydrated();
    const next = compose(state, { type: COMPOSE_LANGUAGE_CHANGE, language: 'en' });

    expect(next.get('language')).toEqual('en');
    expect(next.get('dirty')).toBe(true);
    expect(next.get('idempotencyKey')).not.toEqual(state.get('idempotencyKey'));
  });

  it('inherits an untranslated reply language and keeps the default when a translation is present', () => {
    const state = hydrated();

    expect(compose(state, { type: COMPOSE_REPLY, status: replyStatus() }).get('language')).toEqual('en');
    expect(compose(state, {
      type: COMPOSE_REPLY,
      status: replyStatus({ translation: { content: '<p>こんにちは</p>', language: 'ja' } }),
    }).get('language')).toEqual('ja');
  });

  it('keeps the default language when quoting a post in another language', () => {
    const next = compose(hydrated(), { type: COMPOSE_QUOTE, status: replyStatus() });

    expect(next.get('language')).toEqual('ja');
    expect(next.get('quote_from')).toEqual('s1');
  });

  it('restores the original language when redrafting a status or scheduled post', () => {
    const state = hydrated();
    const redraft = compose(state, {
      type: REDRAFT,
      status: fromJS({
        language: 'en',
        visibility: 'public',
        spoiler_text: '',
        media_attachments: [],
        text: 'Hello',
      }),
      raw_text: 'Hello',
    });
    const scheduled = compose(state, {
      type: REDRAFT,
      status: fromJS({
        language: 'en',
        visibility: 'public',
        spoiler_text: '',
        media_attachments: [],
        text: 'Later',
        scheduled_status_id: 'sched-1',
        scheduled_at: '2099-01-01T00:00:00.000Z',
      }),
      raw_text: 'Later',
    });

    expect(redraft.get('language')).toEqual('en');
    expect(scheduled.get('language')).toEqual('en');
    expect(scheduled.get('scheduled_status_id')).toEqual('sched-1');
  });
});

describe('frequently used languages', () => {
  it('counts a language without requiring an existing history', () => {
    const once = settings(undefined, { type: LANGUAGE_USE, language: 'ja' });
    const twice = settings(once, { type: LANGUAGE_USE, language: 'ja' });

    expect(once.getIn(['frequentlyUsedLanguages', 'ja'])).toEqual(1);
    expect(twice.getIn(['frequentlyUsedLanguages', 'ja'])).toEqual(2);
    expect(twice.get('saved')).toBe(false);
  });
});
