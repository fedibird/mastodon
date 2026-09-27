import { fromJS } from 'immutable';

jest.mock('../../actions/statuses', () => ({
  STATUS_MUTE_SUCCESS: 'STATUS_MUTE_SUCCESS',
  STATUS_UNMUTE_SUCCESS: 'STATUS_UNMUTE_SUCCESS',
  STATUS_REVEAL: 'STATUS_REVEAL',
  STATUS_HIDE: 'STATUS_HIDE',
  STATUS_COLLAPSE: 'STATUS_COLLAPSE',
  STATUS_TRANSLATE_SUCCESS: 'STATUS_TRANSLATE_SUCCESS',
  STATUS_TRANSLATE_UNDO: 'STATUS_TRANSLATE_UNDO',
}));

import reducer from '../statuses';

const STATUS_TRANSLATE_SUCCESS = 'STATUS_TRANSLATE_SUCCESS';
const STATUS_TRANSLATE_UNDO = 'STATUS_TRANSLATE_UNDO';

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
});
