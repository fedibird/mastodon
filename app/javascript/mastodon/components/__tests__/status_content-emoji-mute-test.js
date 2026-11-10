/* eslint-disable react/prop-types */

import { act, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayEmoji: false,
  disableReactions: false,
  translationPrivateContentAllowed: false,
  translationBarVisibility: 'always',
  translationPreferredMode: 'both',
  languages: [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
  ],
}));

jest.mock('react-overlays/Overlay', () => {
  return ({ show, children }) => (show ? children({ props: { style: {} }, placement: 'bottom' }) : null);
});

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'ja-JP',
    formatMessage: ({ defaultMessage }, values) => {
      let message = defaultMessage;

      if (values) {
        Object.keys(values).forEach(key => {
          message = message.replace(`{${key}}`, values[key]);
        });
      }

      return message;
    },
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => intl.formatMessage({ defaultMessage }, values),
  };
});

jest.mock('mastodon/containers/poll_container', () => () => null);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('mastodon/components/icon', () => () => null);

import { EMOJI_MUTES_APPLY } from '../../actions/emoji_mutes';
import emojify from '../../features/emoji/emoji';
import { resetEmojiMuteTextForTests } from '../../features/emoji/emoji_mute_text';
import emojiMutesReducer from '../../reducers/emoji_mutes';
import StatusContent from '../status_content';

const emoji = {
  id: '10',
  shortcode: 'blob',
  url: 'https://cdn.example/blob.svg',
  static_url: 'https://cdn.example/blob.png',
  domain: null,
};

const sourceHtml = emojify('<p>Hello :blob: 👌 <a href="https://example.test/@alice" class="mention">@alice</a></p>', {
  ':blob:': emoji,
}, '');
const spoilerHtml = emojify('Secret :blob:', { ':blob:': emoji }, '');
const translatedHtml = emojify('<p>こんにちは :blob: 👌</p>', { ':blob:': emoji }, '');
const translatedSpoiler = emojify('秘密 :blob:', { ':blob:': emoji }, '');

const muteRule = (overrides = {}) => ({
  id: 'm1',
  revision: '1',
  emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' },
  replacement: '［絵文字］',
  effects: {
    replace_in_text: true,
    reject_reactions_to_own_posts: true,
    hide_reactions: true,
    hide_in_picker: true,
  },
  ...overrides,
});

const unicodeRule = {
  id: 'm2',
  revision: '1',
  emoji: { kind: 'unicode', native: '👌' },
  replacement: '[ok]',
  effects: {
    replace_in_text: true,
    reject_reactions_to_own_posts: false,
    hide_reactions: false,
    hide_in_picker: false,
  },
};

const reducer = (state, action) => state.set('emojiMutes', emojiMutesReducer(state.get('emojiMutes'), action));

const baseState = rules => fromJS({
  server: {
    translationLanguages: {
      items: { en: ['ja'] },
    },
  },
  emojiMutes: {
    revision: '3',
    rules,
  },
});

const buildStatus = (overrides = {}) => fromJS({
  id: 's1',
  contentHtml: sourceHtml,
  spoilerHtml: '',
  spoiler_text: '',
  search_index: 'Hello :blob: 👌 @alice',
  language: 'en',
  visibility: 'public',
  mentions: [],
  tags: [],
  account: { id: 'a1' },
  emojis: [emoji],
  ...overrides,
});

const renderStatus = (status, rules, props = {}) => {
  const store = createStore(reducer, baseState(rules));

  const view = render(
    <Provider store={store}>
      <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} {...props} />
    </Provider>,
  );

  return { ...view, store };
};

describe('StatusContent replace_in_text', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('replaces emoji in the stored body without rewriting that html', () => {
    const status = buildStatus();
    const { container } = renderStatus(status, [muteRule(), unicodeRule]);
    const text = container.querySelector('.status__content__text');

    expect(text.textContent).toBe('Hello ［絵文字］ [ok] @alice');
    expect(text.querySelector('img, source, picture')).toBeNull();
    expect(text.querySelector('a').getAttribute('href')).toBe('https://example.test/@alice');
    expect(status.get('contentHtml')).toBe(sourceHtml);
    expect(status.get('contentHtml')).toContain('https://cdn.example/blob.svg');
    expect(status.get('contentHtml')).toContain('/emoji/');
  });

  it('restores the original body when the mute document no longer replaces it', () => {
    const status = buildStatus();
    const { container, store } = renderStatus(status, [muteRule(), unicodeRule]);

    expect(container.querySelector('img')).toBeNull();

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '4',
        mutes: [],
      });
    });

    const text = container.querySelector('.status__content__text');
    expect(text.querySelector('img.custom-emoji').getAttribute('src')).toBe('https://cdn.example/blob.png');
    expect(text.querySelector('img.emojione:not(.custom-emoji)').getAttribute('alt')).toBe('👌');
    expect(status.get('contentHtml')).toBe(sourceHtml);
  });

  it('does not replace when replace_in_text is false', () => {
    const status = buildStatus();
    const { container } = renderStatus(status, [muteRule({
      effects: {
        replace_in_text: false,
        reject_reactions_to_own_posts: true,
        hide_reactions: true,
        hide_in_picker: true,
      },
    })]);

    expect(container.querySelector('img.custom-emoji').getAttribute('src')).toContain('cdn.example/blob');
    expect(container.querySelector('img.emojione:not(.custom-emoji)').getAttribute('alt')).toBe('👌');
  });

  it('replaces the content warning and both bilingual blocks from the stored html', () => {
    const status = buildStatus({
      spoiler_text: 'Secret :blob:',
      spoilerHtml,
      translationMode: 'bilingual',
      translation: {
        contentHtml: translatedHtml,
        spoilerHtml: translatedSpoiler,
        spoiler_text: '秘密 :blob:',
        language: 'ja',
        detected_source_language: 'en',
        provider: 'test',
      },
    });
    const { container } = renderStatus(status, [muteRule(), unicodeRule]);
    const pairs = container.querySelectorAll('.status-translation-pair');
    const spoiler = container.querySelector('.status__content > p');

    expect(pairs[0].querySelector('.status-translation-pair__source').textContent).toBe('Hello ［絵文字］ [ok] @alice');
    expect(pairs[0].querySelector('.status-translation-pair__target').textContent).toBe('こんにちは ［絵文字］ [ok]');
    expect(pairs[0].querySelector('img, source')).toBeNull();
    expect(spoiler.querySelector('.status-translation-pair__source').textContent).toBe('Secret ［絵文字］');
    expect(spoiler.querySelector('.status-translation-pair__target').textContent).toBe('秘密 ［絵文字］');
    expect(spoiler.querySelector('img, source')).toBeNull();
    expect(status.get('contentHtml')).toBe(sourceHtml);
    expect(status.get('spoilerHtml')).toBe(spoilerHtml);
    expect(status.getIn(['translation', 'contentHtml'])).toBe(translatedHtml);
    expect(status.getIn(['translation', 'spoilerHtml'])).toBe(translatedSpoiler);
  });

  it('replaces only the translated body while that mode is selected', () => {
    const status = buildStatus({
      translationMode: 'translated',
      translation: {
        contentHtml: translatedHtml,
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'en',
        provider: 'test',
      },
    });
    const { container } = renderStatus(status, [muteRule(), unicodeRule]);
    const text = container.querySelector('.status__content__text');

    expect(text.textContent).toBe('こんにちは ［絵文字］ [ok]');
    expect(text.querySelector('img')).toBeNull();
    expect(status.get('contentHtml')).toContain('cdn.example/blob.svg');
    expect(status.getIn(['translation', 'contentHtml'])).toContain('cdn.example/blob.svg');
  });

  it('matches a boosted post and its translation to the author domain', () => {
    const remote = {
      id: '99',
      shortcode: 'blob',
      url: 'https://original.example/blob.svg',
      static_url: 'https://original.example/blob.png',
      domain: 'original.example',
    };
    const authorHtml = emojify('<p>Hello :blob:</p>', { ':blob:': remote }, 'original.example');
    const authorTranslation = emojify('<p>こんにちは :blob:</p>', { ':blob:': remote }, 'original.example');
    const authorMute = muteRule({
      emoji: { kind: 'custom', scope: 'remote', domain: 'original.example', shortcode: 'blob' },
      replacement: '[author]',
    });
    const boosterMute = muteRule({
      id: 'm9',
      emoji: { kind: 'custom', scope: 'remote', domain: 'other.example', shortcode: 'blob' },
      replacement: '[booster]',
    });
    const localMute = muteRule({
      id: 'm8',
      emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '99', shortcode: 'blob' },
      replacement: '[local]',
    });
    const statusFor = mode => buildStatus({
      contentHtml: authorHtml,
      emojis: [remote],
      ...(mode === 'original' ? {} : {
        translationMode: mode,
        translation: {
          contentHtml: authorTranslation,
          spoilerHtml: '',
          language: 'ja',
          detected_source_language: 'en',
          provider: 'test',
        },
      }),
    });

    const original = renderStatus(statusFor('original'), [authorMute]);
    const translated = renderStatus(statusFor('translated'), [authorMute]);
    const bilingual = renderStatus(statusFor('bilingual'), [authorMute]);
    const wrongDomain = renderStatus(statusFor('bilingual'), [boosterMute]);
    const localId = renderStatus(statusFor('translated'), [localMute]);

    expect(original.container.querySelector('.status__content__text').textContent).toBe('Hello [author]');
    expect(translated.container.querySelector('.status__content__text').textContent).toBe('こんにちは [author]');
    expect(bilingual.container.querySelector('.status-translation-pair__source').textContent).toBe('Hello [author]');
    expect(bilingual.container.querySelector('.status-translation-pair__target').textContent).toBe('こんにちは [author]');
    expect(original.container.querySelector('img')).toBeNull();
    expect(translated.container.querySelector('img')).toBeNull();
    expect(bilingual.container.querySelector('img')).toBeNull();
    expect(wrongDomain.container.querySelectorAll('img.custom-emoji')).toHaveLength(2);
    expect(wrongDomain.container.textContent).not.toContain('[booster]');
    expect(localId.container.querySelector('img.custom-emoji').getAttribute('data-domain')).toBe('original.example');
    expect(localId.container.textContent).not.toContain('[local]');
    expect(authorHtml).not.toContain('data-emoji-id');
  });
});
