import { fromJS } from 'immutable';

jest.mock('../../actions/statuses', () => ({
  STATUS_MUTE_SUCCESS: 'STATUS_MUTE_SUCCESS',
  STATUS_UNMUTE_SUCCESS: 'STATUS_UNMUTE_SUCCESS',
  STATUS_REVEAL: 'STATUS_REVEAL',
  STATUS_HIDE: 'STATUS_HIDE',
  STATUS_COLLAPSE: 'STATUS_COLLAPSE',
  STATUS_TRANSLATE_SUCCESS: 'STATUS_TRANSLATE_SUCCESS',
  STATUS_TRANSLATE_UNDO: 'STATUS_TRANSLATE_UNDO',
  STATUS_TRANSLATE_REQUEST: 'STATUS_TRANSLATE_REQUEST',
  STATUS_TRANSLATE_FAIL: 'STATUS_TRANSLATE_FAIL',
  STATUS_TRANSLATE_SET_MODE: 'STATUS_TRANSLATE_SET_MODE',
  STATUS_TRANSLATION_ASSUMPTION: 'STATUS_TRANSLATION_ASSUMPTION',
  STATUS_TRANSLATION_TARGET: 'STATUS_TRANSLATION_TARGET',
}));

import reducer from '../statuses';

const STATUS_TRANSLATE_SUCCESS = 'STATUS_TRANSLATE_SUCCESS';
const STATUS_TRANSLATE_UNDO = 'STATUS_TRANSLATE_UNDO';
const STATUS_TRANSLATE_REQUEST = 'STATUS_TRANSLATE_REQUEST';
const STATUS_TRANSLATE_FAIL = 'STATUS_TRANSLATE_FAIL';
const STATUS_TRANSLATE_SET_MODE = 'STATUS_TRANSLATE_SET_MODE';
const STATUS_TRANSLATION_ASSUMPTION = 'STATUS_TRANSLATION_ASSUMPTION';
const STATUS_TRANSLATION_TARGET = 'STATUS_TRANSLATION_TARGET';

const baseStatus = fromJS({
  id: 's1',
  content: '<p>Hello :blob:</p>',
  spoiler_text: 'secret',
  emojis: [{ shortcode: 'blob', url: 'https://example.test/blob.png', static_url: 'https://example.test/blob.png' }],
  media_attachments: [
    { id: 'm2', description: 'second', type: 'image' },
    { id: 'm1', description: 'first', type: 'image' },
  ],
});

describe('statuses translation reducer', () => {
  it('stores the normalized translation and matches media descriptions by id', () => {
    const state = reducer(fromJS({ s1: baseStatus }), {
      type: STATUS_TRANSLATE_SUCCESS,
      id: 's1',
      domain: 'example.test',
      translation: {
        content: '<p>こんにちは :blob:</p>',
        spoiler_text: '秘密',
        detected_source_language: 'en',
        language: 'ja',
        provider: 'DeepL',
        media_attachments: [
          { id: 'm1', description: 'いち' },
          { id: 'missing', description: 'ignored' },
        ],
      },
    });

    const status = state.get('s1');

    expect(status.getIn(['translation', 'provider'])).toBe('DeepL');
    expect(status.getIn(['translation', 'language'])).toBe('ja');
    expect(status.getIn(['translation', 'detected_source_language'])).toBe('en');
    expect(status.getIn(['translation', 'spoiler_text'])).toBe('秘密');
    expect(status.getIn(['translation', 'contentHtml'])).toContain('こんにちは');
    expect(status.getIn(['translation', 'contentHtml'])).toContain('blob');
    expect(status.getIn(['translation', 'spoilerHtml'])).toContain('秘密');
    expect(status.getIn(['media_attachments', 0, 'translation'])).toBeUndefined();
    expect(status.getIn(['media_attachments', 1, 'translation', 'description'])).toBe('いち');
  });

  it('removes the status translation and every media translation on undo', () => {
    const translated = reducer(fromJS({ s1: baseStatus }), {
      type: STATUS_TRANSLATE_SUCCESS,
      id: 's1',
      translation: {
        content: '<p>こんにちは</p>',
        spoiler_text: '',
        detected_source_language: 'en',
        language: 'ja',
        provider: 'DeepL',
        media_attachments: [
          { id: 'm1', description: 'いち' },
          { id: 'm2', description: 'に' },
        ],
      },
    });

    const state = reducer(translated, {
      type: STATUS_TRANSLATE_UNDO,
      id: 's1',
    });

    expect(state.getIn(['s1', 'translation'])).toBeUndefined();
    expect(state.getIn(['s1', 'media_attachments', 0, 'translation'])).toBeUndefined();
    expect(state.getIn(['s1', 'media_attachments', 1, 'translation'])).toBeUndefined();
    expect(state.getIn(['s1', 'media_attachments', 1, 'description'])).toBe('first');
  });

  it('keeps the requested mode after success and tracks pending', () => {
    const requested = reducer(fromJS({ s1: baseStatus }), {
      type: STATUS_TRANSLATE_REQUEST,
      id: 's1',
      mode: 'bilingual',
      translationRequestId: 'req-mode',
    });

    expect(requested.getIn(['s1', 'translationPending'])).toBe(true);
    expect(requested.getIn(['s1', 'translationRequestId'])).toBe('req-mode');
    expect(requested.getIn(['s1', 'content'])).toBe(baseStatus.get('content'));

    const translated = reducer(requested, {
      type: STATUS_TRANSLATE_SUCCESS,
      id: 's1',
      mode: 'bilingual',
      translationRequestId: 'req-mode',
      translation: {
        content: '<p>こんにちは</p>',
        spoiler_text: '',
        detected_source_language: 'en',
        language: 'ja',
        provider: 'LibreTranslate',
        media_attachments: [
          { id: 'm1', description: 'いち' },
        ],
      },
    });

    expect(translated.getIn(['s1', 'translationPending'])).toBe(false);
    expect(translated.getIn(['s1', 'translationRequestId'])).toBeUndefined();
    expect(translated.getIn(['s1', 'translationMode'])).toBe('bilingual');
    expect(translated.getIn(['s1', 'translation', 'contentHtml'])).toContain('こんにちは');
    expect(translated.getIn(['s1', 'media_attachments', 1, 'translation', 'description'])).toBe('いち');

    const failed = reducer(requested, {
      type: STATUS_TRANSLATE_FAIL,
      id: 's1',
      translationRequestId: 'req-mode',
    });

    expect(failed.getIn(['s1', 'translationPending'])).toBe(false);
    expect(failed.getIn(['s1', 'translationRequestId'])).toBeUndefined();
    expect(failed.getIn(['s1', 'translation'])).toBeUndefined();
  });

  it('ignores a stale translation response after the request id changes', () => {
    const requested = reducer(fromJS({ s1: baseStatus }), {
      type: STATUS_TRANSLATE_REQUEST,
      id: 's1',
      translationRequestId: 'req-a',
    });

    const cleared = requested.deleteIn(['s1', 'translationPending']).deleteIn(['s1', 'translationRequestId']);
    const staleTranslation = {
      content: '<p>古い</p>',
      spoiler_text: '',
      detected_source_language: 'en',
      language: 'ja',
      provider: 'DeepL',
      media_attachments: [],
    };

    const stale = reducer(cleared, {
      type: STATUS_TRANSLATE_SUCCESS,
      id: 's1',
      mode: 'translated',
      translationRequestId: 'req-a',
      translation: staleTranslation,
    });

    expect(stale.getIn(['s1', 'translation'])).toBeUndefined();

    const requestedAgain = reducer(cleared, {
      type: STATUS_TRANSLATE_REQUEST,
      id: 's1',
      translationRequestId: 'req-b',
    });

    const ignored = reducer(requestedAgain, {
      type: STATUS_TRANSLATE_SUCCESS,
      id: 's1',
      mode: 'translated',
      translationRequestId: 'req-a',
      translation: staleTranslation,
    });

    expect(ignored.getIn(['s1', 'translation'])).toBeUndefined();
    expect(ignored.getIn(['s1', 'translationPending'])).toBe(true);
    expect(ignored.getIn(['s1', 'translationRequestId'])).toBe('req-b');

    const ignoredFailure = reducer(requestedAgain, {
      type: STATUS_TRANSLATE_FAIL,
      id: 's1',
      translationRequestId: 'req-a',
    });

    expect(ignoredFailure.getIn(['s1', 'translationPending'])).toBe(true);
    expect(ignoredFailure.getIn(['s1', 'translationRequestId'])).toBe('req-b');

    const saved = reducer(requestedAgain, {
      type: STATUS_TRANSLATE_SUCCESS,
      id: 's1',
      mode: 'bilingual',
      translationRequestId: 'req-b',
      translation: {
        content: '<p>新しい</p>',
        spoiler_text: '',
        detected_source_language: 'en',
        language: 'ja',
        provider: 'DeepL',
        media_attachments: [],
      },
    });

    expect(saved.getIn(['s1', 'translation', 'contentHtml'])).toContain('新しい');
    expect(saved.getIn(['s1', 'translationMode'])).toBe('bilingual');
    expect(saved.getIn(['s1', 'translationPending'])).toBe(false);
    expect(saved.getIn(['s1', 'translationRequestId'])).toBeUndefined();
  });

  it('changes display mode without deleting translation, media, or poll data', () => {
    const translated = reducer(fromJS({ s1: baseStatus.set('poll', 'p1') }), {
      type: STATUS_TRANSLATE_SUCCESS,
      id: 's1',
      mode: 'translated',
      translation: {
        content: '<p>こんにちは</p>',
        spoiler_text: '',
        detected_source_language: 'en',
        language: 'ja',
        provider: 'DeepL',
        media_attachments: [
          { id: 'm1', description: 'いち' },
          { id: 'm2', description: 'に' },
        ],
      },
    });

    const original = reducer(translated, {
      type: STATUS_TRANSLATE_SET_MODE,
      id: 's1',
      mode: 'original',
    });

    expect(original.getIn(['s1', 'translationMode'])).toBe('original');
    expect(original.getIn(['s1', 'translation', 'contentHtml'])).toContain('こんにちは');
    expect(original.getIn(['s1', 'media_attachments', 0, 'translation', 'description'])).toBe('に');
    expect(original.getIn(['s1', 'media_attachments', 1, 'translation', 'description'])).toBe('いち');
    expect(original.getIn(['s1', 'poll'])).toBe('p1');

    const bilingual = reducer(original, {
      type: STATUS_TRANSLATE_SET_MODE,
      id: 's1',
      mode: 'bilingual',
    });

    expect(bilingual.getIn(['s1', 'translationMode'])).toBe('bilingual');
    expect(bilingual.getIn(['s1', 'translation', 'provider'])).toBe('DeepL');
    expect(bilingual.getIn(['s1', 'media_attachments', 1, 'translation', 'description'])).toBe('いち');
  });

  it('keeps the requested language pair on the translation and ignores a stale pair', () => {
    const requested = reducer(fromJS({ s1: baseStatus.set('language', 'ja').set('poll', 'p1') }), {
      type: STATUS_TRANSLATE_REQUEST,
      id: 's1',
      translationRequestId: 'req-a',
    });

    const changed = reducer(requested, {
      type: STATUS_TRANSLATION_ASSUMPTION,
      id: 's1',
      source: 'en',
      target: 'ja',
    });

    expect(changed.getIn(['s1', 'language'])).toBe('ja');
    expect(changed.getIn(['s1', 'translationPending'])).toBe(false);
    expect(changed.getIn(['s1', 'translationRequestId'])).toBeUndefined();
    expect(changed.getIn(['s1', 'poll'])).toBe('p1');

    const stale = reducer(changed, {
      type: STATUS_TRANSLATE_SUCCESS,
      id: 's1',
      mode: 'translated',
      translationRequestId: 'req-a',
      translation: {
        content: '<p>古い</p>',
        spoiler_text: '',
        detected_source_language: 'ja',
        language: 'en',
        provider: 'DeepL',
        requested_source_language: 'ja',
        requested_target_language: 'en',
        media_attachments: [{ id: 'm1', description: '古い' }],
      },
    });

    expect(stale.getIn(['s1', 'translation'])).toBeUndefined();
    expect(stale.getIn(['s1', 'media_attachments', 1, 'translation'])).toBeUndefined();
    expect(stale.getIn(['s1', 'translationMode'])).toBeUndefined();

    const current = reducer(changed, {
      type: STATUS_TRANSLATE_REQUEST,
      id: 's1',
      translationRequestId: 'req-b',
    });
    const saved = reducer(current, {
      type: STATUS_TRANSLATE_SUCCESS,
      id: 's1',
      mode: 'translated',
      translationRequestId: 'req-b',
      translation: {
        content: '<p>こんにちは</p>',
        spoiler_text: '',
        detected_source_language: 'en',
        language: 'ja',
        provider: 'DeepL',
        requested_source_language: 'en',
        requested_target_language: 'ja',
        media_attachments: [],
      },
    });

    expect(saved.getIn(['s1', 'translation', 'requested_source_language'])).toBe('en');
    expect(saved.getIn(['s1', 'translation', 'requested_target_language'])).toBe('ja');
    expect(saved.getIn(['s1', 'translation', 'detected_source_language'])).toBe('en');
    expect(saved.getIn(['s1', 'language'])).toBe('ja');
  });

  it('clears every in-flight request and returns loaded translations to original when the viewer target changes', () => {
    const state = fromJS({
      s1: {
        id: 's1',
        language: 'en',
        translationPending: true,
        translationRequestId: 'req-a',
        translationMode: 'translated',
        poll: 'p1',
        translation: {
          content: '<p>こんにちは</p>',
          provider: 'DeepL',
          requested_source_language: 'en',
          requested_target_language: 'ja',
        },
        media_attachments: [
          { id: 'm1', description: 'first', translation: { description: 'いち' } },
        ],
      },
      s2: {
        id: 's2',
        language: 'fr',
        translationPending: true,
        translationRequestId: 'req-b',
        poll: 'p2',
      },
    });

    const next = reducer(state, {
      type: STATUS_TRANSLATION_TARGET,
      target: 'de',
    });

    expect(next.getIn(['s1', 'translationPending'])).toBe(false);
    expect(next.getIn(['s1', 'translationRequestId'])).toBeUndefined();
    expect(next.getIn(['s1', 'translationMode'])).toBe('original');
    expect(next.getIn(['s1', 'language'])).toBe('en');
    expect(next.getIn(['s1', 'poll'])).toBe('p1');
    expect(next.getIn(['s1', 'translation', 'provider'])).toBe('DeepL');
    expect(next.getIn(['s1', 'translation', 'requested_target_language'])).toBe('ja');
    expect(next.getIn(['s1', 'media_attachments', 0, 'description'])).toBe('first');
    expect(next.getIn(['s1', 'media_attachments', 0, 'translation', 'description'])).toBe('いち');
    expect(next.getIn(['s2', 'translationPending'])).toBe(false);
    expect(next.getIn(['s2', 'translationRequestId'])).toBeUndefined();
    expect(next.getIn(['s2', 'translation'])).toBeUndefined();
    expect(next.getIn(['s2', 'translationMode'])).toBeUndefined();
    expect(next.getIn(['s2', 'language'])).toBe('fr');
    expect(next.getIn(['s2', 'poll'])).toBe('p2');

    const staleSuccess = reducer(next, {
      type: STATUS_TRANSLATE_SUCCESS,
      id: 's1',
      mode: 'translated',
      translationRequestId: 'req-a',
      translation: {
        content: '<p>古い</p>',
        language: 'de',
        provider: 'Other',
        requested_source_language: 'en',
        requested_target_language: 'de',
      },
    });
    const staleFailure = reducer(next, {
      type: STATUS_TRANSLATE_FAIL,
      id: 's2',
      translationRequestId: 'req-b',
    });

    expect(staleSuccess.getIn(['s1', 'translation', 'provider'])).toBe('DeepL');
    expect(staleSuccess.getIn(['s1', 'translationMode'])).toBe('original');
    expect(staleSuccess.getIn(['s1', 'language'])).toBe('en');
    expect(staleFailure.getIn(['s2', 'language'])).toBe('fr');
    expect(staleFailure.getIn(['s2', 'poll'])).toBe('p2');
    expect(staleFailure.getIn(['s2', 'translationRequestId'])).toBeUndefined();
  });

  it('normalizes a personal boost from the boosted status and stores it on the wrapper', () => {
    const proper = fromJS({
      id: 'proper',
      content: '<p>Hello :blob:</p>',
      spoiler_text: '',
      emojis: [{ shortcode: 'blob', url: 'https://example.test/blob.png', static_url: 'https://example.test/blob.png' }],
      media_attachments: [
        { id: 'm1', description: 'a cat', type: 'image' },
      ],
    });
    const wrapper = fromJS({
      id: 'wrap',
      content: '',
      spoiler_text: '',
      emojis: [],
      media_attachments: [],
      reblog: 'proper',
      visibility: 'personal',
    });

    const state = reducer(fromJS({ wrap: wrapper, proper }), {
      type: STATUS_TRANSLATE_SUCCESS,
      id: 'wrap',
      contentStatusId: 'proper',
      domain: 'example.test',
      mode: 'bilingual',
      translation: {
        content: '<p>こんにちは :blob:</p>',
        spoiler_text: '',
        detected_source_language: 'en',
        language: 'ja',
        provider: 'DeepL',
        media_attachments: [
          { id: 'm1', description: 'ねこ' },
        ],
      },
    });

    expect(state.getIn(['wrap', 'translation', 'contentHtml'])).toContain('data-shortcode="blob"');
    expect(state.getIn(['wrap', 'translation', 'contentHtml'])).toContain('こんにちは');
    expect(state.getIn(['wrap', 'translationMode'])).toBe('bilingual');
    expect(state.getIn(['wrap', 'translation', 'media_attachments', 0, 'id'])).toBe('m1');
    expect(state.getIn(['wrap', 'translation', 'media_attachments', 0, 'description'])).toBe('ねこ');
    expect(state.getIn(['wrap', 'media_attachments']).size).toBe(0);
    expect(state.get('proper')).toBe(proper);
    expect(state.getIn(['proper', 'translation'])).toBeUndefined();
    expect(state.getIn(['proper', 'media_attachments', 0, 'translation'])).toBeUndefined();
    expect(state.getIn(['proper', 'media_attachments', 0, 'description'])).toBe('a cat');
  });
});
