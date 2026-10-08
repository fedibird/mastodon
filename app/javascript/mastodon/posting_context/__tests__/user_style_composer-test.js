import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet, fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../uuid', () => ({
  __esModule: true,
  default: () => 'test-idempotency-key',
}));

import { COMPOSE_QUOTE_CANCEL, COMPOSE_REPLY, COMPOSE_REPLY_CANCEL, COMPOSE_SENSITIVITY_CHANGE, COMPOSE_SPOILERNESS_CHANGE, COMPOSE_SUBMIT_SUCCESS, COMPOSE_UPLOAD_SUCCESS, COMPOSE_UPLOAD_UNDO, COMPOSE_VISIBILITY_CHANGE, changeCompose, setComposeToStatus } from '../../actions/compose';
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

  it('drops a previous style value when the next style inherits that field', () => {
    const privateStyle = circleStyle.set('defaults', fromJS({
      visibility: 'private',
      language: { mode: 'explicit', code: 'en' },
      sensitive: true,
      spoiler: { enabled: true, text: 'note' },
    })).setIn(['target', 'kind'], 'none');
    const inherited = hashtagStyle.set('defaults', fromJS({}));
    const applied = commit(composer(undefined, changeCompose('Keep me')), privateStyle);
    const next = commit(applied, inherited);

    expect(applied.get('privacy')).toEqual('private');
    expect(applied.get('language')).toEqual('en');
    expect(applied.get('spoiler')).toBe(true);
    expect(applied.get('sensitive')).toBe(true);
    expect(next.get('text')).toEqual('Keep me');
    expect(next.get('privacy')).toEqual('public');
    expect(next.get('language')).toBeNull();
    expect(next.get('spoiler')).toBe(false);
    expect(next.get('spoiler_text')).toEqual('');
    expect(next.get('sensitive')).toBe(false);
    expect(next.getIn(['userPostingStyle', 'styleOwnedFields']).isEmpty()).toBe(true);
  });

  it('keeps a manual value when switching to a style that inherits it', () => {
    const applied = commit(undefined, circleStyle.setIn(['target', 'kind'], 'none'));
    const manual = composer(applied, { type: COMPOSE_VISIBILITY_CHANGE, value: 'unlisted' });
    const inherited = hashtagStyle.set('defaults', fromJS({})).setIn(['target', 'kind'], 'none');
    const next = commit(manual, inherited);

    expect(next.get('privacy')).toEqual('unlisted');
    expect(next.get('text')).toEqual('');
    expect(next.getIn(['userPostingStyle', 'manualFields']).includes('privacy')).toBe(true);
  });

  it('restores the account sensitive default for attached media', () => {
    const marked = fromJS({
      id: '9',
      revision: 1,
      target: { kind: 'none' },
      defaults: { sensitive: true },
    });
    const drafted = composer(undefined, { type: '@@INIT' })
      .set('default_sensitive', true)
      .set('media_attachments', ImmutableList([ImmutableMap({ id: 'media-1' })]));
    const applied = commit(drafted, marked);
    const next = commit(applied, null);

    expect(applied.get('sensitive')).toBe(true);
    expect(next.get('sensitive')).toBe(true);
    expect(next.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
  });

  it('marks media sensitive when a style turns the content warning on', () => {
    const warned = fromJS({
      id: '8',
      revision: 1,
      target: { kind: 'none' },
      defaults: { spoiler: { enabled: true, text: 'cw' } },
    });
    const drafted = composer(undefined, { type: '@@INIT' })
      .set('media_attachments', ImmutableList([ImmutableMap({ id: 'media-1' })]));
    const next = commit(drafted, warned);

    expect(next.get('spoiler')).toBe(true);
    expect(next.get('sensitive')).toBe(true);
    expect(next.getIn(['userPostingStyle', 'styleOwnedFields']).includes('sensitive')).toBe(true);
  });

  it('restores the style after leaving a reply or quote', () => {
    const applied = commit(composer(undefined, changeCompose('Hello')), circleStyle.setIn(['target', 'kind'], 'none'));
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
    const restored = composer(reply, { type: COMPOSE_REPLY_CANCEL });

    expect(reply.get('privacy')).toEqual('public');
    expect(restored.get('in_reply_to')).toBeNull();
    expect(restored.get('privacy')).toEqual('private');
    expect(restored.get('language')).toBeNull();
    expect(restored.get('text')).toEqual('');

    const quote = composer(restored, {
      type: 'COMPOSE_QUOTE',
      status: fromJS({
        id: 's2',
        url: 'https://example.test/s2',
        visibility: 'public',
        spoiler_text: 'secret',
      }),
    });
    const afterQuote = composer(quote, { type: COMPOSE_QUOTE_CANCEL });

    expect(quote.get('spoiler')).toBe(true);
    expect(afterQuote.get('quote_from')).toBeNull();
    expect(afterQuote.get('spoiler')).toBe(true);
    expect(afterQuote.get('spoiler_text')).toEqual('note');
    expect(afterQuote.get('privacy')).toEqual('private');
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

  it('does not let an attached file replace an explicit sensitive off with the account default', () => {
    const off = fromJS({
      id: '9',
      revision: 1,
      target: { kind: 'none' },
      defaults: { sensitive: false },
    });
    const applied = commit(composer(undefined, { type: '@@INIT' }).set('default_sensitive', true), off);
    const withMedia = composer(applied, {
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'm1', type: 'image' },
    });

    expect(withMedia.get('sensitive')).toBe(false);
    expect(withMedia.get('media_attachments').size).toEqual(1);
    expect(withMedia.getIn(['userPostingStyle', 'manualFields']).includes('sensitive')).toBe(false);

    const blankWarning = fromJS({
      id: '12',
      revision: 1,
      target: { kind: 'none' },
      defaults: { sensitive: false, spoiler: { enabled: true, text: '  ' } },
    });
    const blank = commit(withMedia, blankWarning);

    expect(blank.get('spoiler')).toBe(true);
    expect(blank.get('sensitive')).toBe(false);
  });

  it('restores an explicit sensitive on after media is removed and attached again', () => {
    const on = fromJS({
      id: '9',
      revision: 1,
      target: { kind: 'none' },
      defaults: { sensitive: true },
    });
    const applied = commit(undefined, on);
    const withMedia = composer(applied, {
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'm1', type: 'image' },
    });
    const removed = composer(withMedia, { type: COMPOSE_UPLOAD_UNDO, media_id: 'm1' });
    const again = composer(removed, {
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'm2', type: 'image' },
    });

    expect(withMedia.get('sensitive')).toBe(true);
    expect(removed.get('sensitive')).toBe(false);
    expect(removed.get('media_attachments').size).toEqual(0);
    expect(removed.getIn(['userPostingStyle', 'styleOwnedFields']).includes('sensitive')).toBe(true);
    expect(again.get('sensitive')).toBe(true);
    expect(again.getIn(['userPostingStyle', 'manualFields']).includes('sensitive')).toBe(false);
  });

  it('keeps the usual media sensitive default when no style pins it', () => {
    const drafted = composer(undefined, { type: '@@INIT' }).set('default_sensitive', true);
    const withMedia = composer(drafted, {
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'm1', type: 'image' },
    });
    const removed = composer(withMedia, { type: COMPOSE_UPLOAD_UNDO, media_id: 'm1' });
    const warned = composer(composer(undefined, { type: COMPOSE_SPOILERNESS_CHANGE }), {
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'm2', type: 'image' },
    });

    expect(withMedia.get('sensitive')).toBe(true);
    expect(removed.get('sensitive')).toBe(false);
    expect(warned.get('spoiler')).toBe(true);
    expect(warned.get('sensitive')).toBe(true);
  });

  it('shows sensitive on for a content warning with text, including when another warning style is selected', () => {
    const first = fromJS({
      id: '8',
      revision: 1,
      target: { kind: 'none' },
      defaults: { sensitive: false, spoiler: { enabled: true, text: 'cw' } },
    });
    const second = fromJS({
      id: '10',
      revision: 1,
      target: { kind: 'none' },
      defaults: { sensitive: false, spoiler: { enabled: true, text: 'other' } },
    });
    const drafted = composer(composer(undefined, { type: '@@INIT' }).set('default_sensitive', true), {
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'm1', type: 'image' },
    });
    const applied = commit(drafted, first);
    const switched = commit(applied, second);
    const removed = composer(switched, { type: COMPOSE_UPLOAD_UNDO, media_id: 'm1' });

    expect(applied.get('sensitive')).toBe(true);
    expect(applied.get('spoiler_text')).toEqual('cw');
    expect(switched.get('spoiler_text')).toEqual('other');
    expect(switched.get('sensitive')).toBe(true);
    expect(removed.get('sensitive')).toBe(true);
    expect(removed.getIn(['userPostingStyle', 'manualFields']).includes('sensitive')).toBe(false);
  });

  it('keeps a manual sensitive value distinct from a style value', () => {
    const manual = composer(composer(undefined, { type: '@@INIT' }).set('sensitive', true), {
      type: COMPOSE_SENSITIVITY_CHANGE,
    });
    const warned = fromJS({
      id: '8',
      revision: 1,
      target: { kind: 'none' },
      defaults: { spoiler: { enabled: true, text: 'cw' } },
    });
    const plain = fromJS({
      id: '11',
      revision: 1,
      target: { kind: 'none' },
      defaults: { spoiler: { enabled: false } },
    });
    const applied = commit(manual, warned);
    const restored = commit(applied, plain);

    expect(manual.get('sensitive')).toBe(false);
    expect(manual.getIn(['userPostingStyle', 'manualFields']).includes('sensitive')).toBe(true);
    expect(applied.get('sensitive')).toBe(true);
    expect(applied.get('spoiler')).toBe(true);
    expect(restored.get('spoiler')).toBe(false);
    expect(restored.get('sensitive')).toBe(false);
    expect(restored.getIn(['userPostingStyle', 'manualFields']).includes('sensitive')).toBe(true);
  });

  it('rotates the idempotency key when an effective post value changes and keeps it when nothing changes', () => {
    const drafted = composer(undefined, changeCompose('Hello')).set('idempotencyKey', 'previous-key');
    const privateStyle = fromJS({
      id: '3',
      revision: 1,
      target: { kind: 'none' },
      defaults: { visibility: 'private' },
      managed: { hashtags: [] },
    });
    const languageStyle = fromJS({
      id: '4',
      revision: 1,
      target: { kind: 'none' },
      defaults: { language: { mode: 'explicit', code: 'en' } },
      managed: { hashtags: [] },
    });
    const warningStyle = fromJS({
      id: '5',
      revision: 1,
      target: { kind: 'none' },
      defaults: { spoiler: { enabled: true, text: 'cw' }, sensitive: true },
      managed: { hashtags: [] },
    });

    const byPrivacy = commit(drafted, privateStyle);
    expect(byPrivacy.get('text')).toEqual('Hello');
    expect(byPrivacy.get('privacy')).toEqual('private');
    expect(byPrivacy.get('idempotencyKey')).toEqual('test-idempotency-key');

    const byLanguage = commit(byPrivacy.set('idempotencyKey', 'kept-key'), languageStyle);
    expect(byLanguage.get('language')).toEqual('en');
    expect(byLanguage.get('privacy')).toEqual('public');
    expect(byLanguage.get('idempotencyKey')).toEqual('test-idempotency-key');

    const byWarning = commit(byLanguage.set('idempotencyKey', 'kept-key'), warningStyle);
    expect(byWarning.get('spoiler')).toBe(true);
    expect(byWarning.get('sensitive')).toBe(true);
    expect(byWarning.get('idempotencyKey')).toEqual('test-idempotency-key');

    const again = commit(byWarning.set('idempotencyKey', 'kept-key'), warningStyle);
    expect(again.get('idempotencyKey')).toEqual('kept-key');
    expect(again.get('spoiler_text')).toEqual('cw');
  });

  it('rotates the idempotency key only when the sent hashtag text changes', () => {
    const spelled = (id, name, tagName, target = { kind: 'none' }) => fromJS({
      id,
      name,
      icon: '✦',
      revision: 1,
      target,
      defaults: {},
      managed: { hashtags: [{ name: tagName, normalizedName: tagName.toLowerCase(), enforcement: 'advisory' }] },
    });
    const drafted = composer(undefined, changeCompose('Hello')).set('idempotencyKey', 'previous-key');
    const wide = commit(drafted, spelled('21', 'Wide', 'Fedibird'));
    const lower = commit(wide.set('idempotencyKey', 'kept-key'), spelled('22', 'Lower', 'fedibird'));
    const renamed = commit(lower.set('idempotencyKey', 'kept-key'), spelled('23', 'Alias', 'fedibird'));
    const destination = commit(renamed.set('idempotencyKey', 'kept-key'), spelled('24', 'Destination', 'fedibird', {
      kind: 'hashtag',
      hashtag: 'fedibird',
      label: '#fedibird',
    }));
    const changedOrigin = commit(wide.set('idempotencyKey', 'kept-key'), spelled('25', 'Mixed', 'Fedibird', {
      kind: 'hashtag',
      hashtag: 'fedibird',
      label: '#fedibird',
    }));
    const suppressed = composer(changedOrigin.set('idempotencyKey', 'kept-key'), {
      type: USER_POSTING_STYLE_HASHTAG_TOGGLE,
      origin: 'destination',
      normalizedName: 'fedibird',
    });
    const sameOrigin = commit(drafted.set('idempotencyKey', 'kept-key'), spelled('24', 'Destination', 'fedibird', {
      kind: 'hashtag',
      hashtag: 'fedibird',
      label: '#fedibird',
    }));
    const suppressedSame = composer(sameOrigin.set('idempotencyKey', 'kept-key'), {
      type: USER_POSTING_STYLE_HASHTAG_TOGGLE,
      origin: 'destination',
      normalizedName: 'fedibird',
    });
    const alreadyWritten = commit(composer(undefined, changeCompose('Hello #Fedibird')).set('idempotencyKey', 'kept-key'), spelled('22', 'Lower', 'fedibird'));

    expect(materializeComposerText(wide)).toEqual('Hello\n\n#Fedibird');
    expect(wide.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(materializeComposerText(lower)).toEqual('Hello\n\n#fedibird');
    expect(lower.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(materializeComposerText(renamed)).toEqual('Hello\n\n#fedibird');
    expect(renamed.get('idempotencyKey')).toEqual('kept-key');
    expect(materializeComposerText(destination)).toEqual('Hello\n\n#fedibird');
    expect(destination.get('idempotencyKey')).toEqual('kept-key');
    expect(materializeComposerText(changedOrigin)).toEqual('Hello\n\n#fedibird');
    expect(changedOrigin.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(materializeComposerText(suppressed)).toEqual('Hello\n\n#Fedibird');
    expect(suppressed.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(materializeComposerText(suppressedSame)).toEqual('Hello\n\n#fedibird');
    expect(suppressedSame.get('idempotencyKey')).toEqual('kept-key');
    expect(materializeComposerText(alreadyWritten)).toEqual('Hello #Fedibird');
    expect(alreadyWritten.get('idempotencyKey')).toEqual('kept-key');
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
