import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet, fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../uuid', () => ({
  __esModule: true,
  default: () => 'test-idempotency-key',
}));

import { COMPOSE_REPLY, COMPOSE_SUBMIT_SUCCESS, COMPOSE_VISIBILITY_CHANGE, changeCompose, setComposeToStatus } from '../../actions/compose';
import { createComposer, targetComposerAction } from '../../actions/composer';
import { USER_POSTING_STYLE_COMMIT, USER_POSTING_STYLE_HASHTAG_TOGGLE } from '../../actions/user_posting_styles';
import { selectComposerPostingContextCompliance } from '../compliance';
import { materializeComposerText } from '../materialize';
import { resolveUserPostingStyle } from '../user_style_resolver';
import compose from '../../reducers/compose';
import composer from '../../reducers/composer';
import composers from '../../reducers/composers';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';

const circleStyle = fromJS({
  id: '1',
  name: 'サークル告知',
  icon: '📣',
  purpose: 'サークル向けの告知',
  revision: 4,
  target: { kind: 'group', accountId: '123', hashtag: null, label: 'localsquad' },
  defaults: {
    visibility: 'private',
    language: { mode: 'auto' },
    sensitive: true,
    spoiler: { enabled: true, text: 'note' },
  },
  managed: {
    hashtags: [{ name: 'fedibird', normalizedName: 'fedibird', enforcement: 'advisory' }],
  },
});

const hashtagStyle = fromJS({
  id: '2',
  name: '読書メモ',
  icon: '📚',
  purpose: '読んだ本',
  revision: 1,
  target: { kind: 'hashtag', accountId: null, hashtag: 'books', label: '#books' },
  defaults: { visibility: 'unlisted' },
  managed: {
    hashtags: [{ name: 'fedibird', normalizedName: 'fedibird', enforcement: 'advisory' }],
  },
});

const commit = (state, style) => composer(state, {
  type: USER_POSTING_STYLE_COMMIT,
  plan: resolveUserPostingStyle(style, state || composer(undefined, { type: '@@INIT' })),
  snapshot: style,
  resetSuppressions: true,
  restoreParked: false,
});

describe('composer posting styles', () => {
  it('applies spoiler and sensitive together without changing the draft body', () => {
    const drafted = composer(undefined, changeCompose('Hello'))
      .set('media_attachments', ImmutableList([ImmutableMap({ id: 'media-1' })]))
      .set('poll', ImmutableMap({ options: ImmutableList(['a']) }))
      .set('idempotencyKey', 'previous-key');
    const next = commit(drafted, circleStyle);

    expect(next.get('text')).toEqual('Hello');
    expect(next.get('media_attachments')).toBe(drafted.get('media_attachments'));
    expect(next.get('poll')).toBe(drafted.get('poll'));
    expect(next.get('spoiler')).toBe(true);
    expect(next.get('spoiler_text')).toEqual('note');
    expect(next.get('sensitive')).toBe(true);
    expect(next.get('privacy')).toEqual('private');
    expect(next.get('language')).toBeNull();
    expect(next.getIn(['userPostingStyle', 'selectedId'])).toEqual('1');
    expect(next.getIn(['userPostingStyle', 'appliedRevision'])).toEqual(4);
    expect(next.getIn(['userPostingStyle', 'destinationStatus'])).toEqual('pending');
    expect(next.getIn(['context', 'key'])).toBeNull();
    expect(next.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(materializeComposerText(next)).toEqual('Hello\n\n#fedibird');
  });

  it('keeps a manually chosen visibility when the style is switched', () => {
    const manual = composer(composer(undefined, { type: COMPOSE_VISIBILITY_CHANGE, value: 'unlisted' }), changeCompose('Hello'));
    const next = commit(manual, circleStyle);

    expect(next.get('privacy')).toEqual('unlisted');
    expect(next.getIn(['userPostingStyle', 'unapplied']).includes('privacy')).toBe(true);
    expect(next.get('language')).toBeNull();
    expect(next.get('dirty')).toBe(true);
  });

  it('does not treat the text dirty flag as a per-field override', () => {
    const next = commit(composer(undefined, changeCompose('Hello')), circleStyle);

    expect(next.get('privacy')).toEqual('private');
  });

  it('adds a destination hashtag separately from a style hashtag and updates the key only when output changes', () => {
    const applied = commit(composer(undefined, changeCompose('Hello')).set('idempotencyKey', 'previous-key'), hashtagStyle);
    const suppressed = composer(applied.set('idempotencyKey', 'kept-key'), {
      type: USER_POSTING_STYLE_HASHTAG_TOGGLE,
      origin: 'style',
      normalizedName: 'fedibird',
    });

    expect(materializeComposerText(applied)).toEqual('Hello\n\n#fedibird #books');
    expect(applied.getIn(['userPostingStyle', 'destinationStatus'])).toEqual('ready');
    expect(applied.getIn(['context', 'managed', 'mentions']).isEmpty()).toBe(true);
    expect(materializeComposerText(suppressed)).toEqual('Hello\n\n#books');
    expect(suppressed.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(suppressed.get('text')).toEqual('Hello');

    const again = composer(suppressed.set('idempotencyKey', 'kept-key'), {
      type: USER_POSTING_STYLE_HASHTAG_TOGGLE,
      origin: 'destination',
      normalizedName: 'books',
    });

    expect(materializeComposerText(again)).toEqual('Hello');
    expect(again.getIn(['userPostingStyle', 'suppressions']).includes('style:fedibird')).toBe(true);
    expect(again.getIn(['userPostingStyle', 'suppressions']).includes('destination:books')).toBe(true);
  });

  it('does not retarget a reply, quote, edit, or scheduled edit', () => {
    const applied = commit(undefined, circleStyle);
    const reply = composer(applied, {
      type: COMPOSE_REPLY,
      status: fromJS({
        id: 's1',
        language: 'en',
        visibility: 'public',
        spoiler_text: '',
        mentions: [],
        account: { id: '2', acct: 'bob' },
      }),
    });

    expect(reply.get('in_reply_to')).toEqual('s1');
    expect(reply.getIn(['userPostingStyle', 'destinationStatus'])).toEqual('skipped');
    expect(reply.getIn(['context', 'key'])).toBeNull();
    expect(materializeComposerText(reply)).not.toContain('@group');

    const quote = composer(applied, {
      type: 'COMPOSE_QUOTE',
      status: fromJS({
        id: 's2',
        url: 'https://example.test/s2',
        visibility: 'public',
        spoiler_text: '',
      }),
    });

    expect(quote.get('quote_from')).toEqual('s2');
    expect(quote.getIn(['userPostingStyle', 'destinationStatus'])).toEqual('skipped');
    expect(quote.getIn(['context', 'key'])).toBeNull();

    const editing = composer(applied, setComposeToStatus(fromJS({
      id: 'status-1',
      visibility: 'public',
      sensitive: false,
    }), 'Hello', ''));
    const scheduled = applied.set('scheduled_status_id', 'sched-1');

    expect(composer(editing, { type: USER_POSTING_STYLE_COMMIT, plan: { blocked: false }, snapshot: hashtagStyle })).toBe(editing);
    expect(composer(scheduled, { type: USER_POSTING_STYLE_COMMIT, plan: { blocked: false }, snapshot: hashtagStyle })).toBe(scheduled);
  });

  it('reapplies the selected style after a successful post', () => {
    const applied = commit(composer(undefined, changeCompose('Hello')), hashtagStyle);
    const next = composer(applied, { type: COMPOSE_SUBMIT_SUCCESS });

    expect(next.get('text')).toEqual('');
    expect(next.get('privacy')).toEqual('unlisted');
    expect(next.getIn(['userPostingStyle', 'selectedId'])).toEqual('2');
    expect(next.getIn(['userPostingStyle', 'manualFields']).isEmpty()).toBe(true);
    expect(next.getIn(['userPostingStyle', 'destinationStatus'])).toEqual('ready');
    expect(materializeComposerText(next)).toEqual('#fedibird #books');
  });

  it('blocks submit while a group destination is unresolved and does not rewrite visibility', () => {
    const applied = commit(composer(undefined, changeCompose('Hello')), circleStyle);
    const state = ImmutableMap({
      compose: applied,
      relationships: ImmutableMap(),
    });
    const compliance = selectComposerPostingContextCompliance(state, PRIMARY_COMPOSER_ID);

    expect(applied.get('privacy')).toEqual('private');
    expect(compliance.valid).toBe(false);
    expect(compliance.destination.status).toEqual('pending');
  });

  it('keeps a style on one composer from reaching another', () => {
    let state = composers(undefined, createComposer('composer-a'));
    state = composers(state, createComposer('composer-b'));
    const current = state.getIn(['byId', 'composer-a']);
    state = composers(state, targetComposerAction({
      type: USER_POSTING_STYLE_COMMIT,
      plan: resolveUserPostingStyle(hashtagStyle, current),
      snapshot: hashtagStyle,
      resetSuppressions: true,
    }, 'composer-a'));

    expect(state.getIn(['byId', 'composer-a', 'privacy'])).toEqual('unlisted');
    expect(state.getIn(['byId', 'composer-b', 'privacy'])).toBeNull();
    expect(state.getIn(['byId', 'composer-b', 'userPostingStyle', 'selectedId'])).toBeNull();
    expect(compose(composer(undefined, { type: '@@INIT' }), targetComposerAction({
      type: USER_POSTING_STYLE_COMMIT,
      plan: resolveUserPostingStyle(hashtagStyle, composer(undefined, { type: '@@INIT' })),
      snapshot: hashtagStyle,
      resetSuppressions: true,
    }, 'composer-a')).get('privacy')).toBeNull();
  });
});

describe('user posting style hashtag toggle', () => {
  it('leaves context suppression independent', () => {
    const applied = commit(undefined, hashtagStyle);
    const toggled = composer(applied, {
      type: USER_POSTING_STYLE_HASHTAG_TOGGLE,
      origin: 'style',
      normalizedName: 'fedibird',
    });

    expect(toggled.getIn(['context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
    expect(toggled.getIn(['userPostingStyle', 'suppressions']).equals(ImmutableSet(['style:fedibird']))).toBe(true);
  });
});
