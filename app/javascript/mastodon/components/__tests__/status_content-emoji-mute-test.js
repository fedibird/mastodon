/* eslint-disable react/prop-types */

import { act, fireEvent, render } from '@testing-library/react';
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

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_DISABLE, EMOJI_MUTES_IGNORE, EMOJI_MUTES_REVISION } from '../../actions/emoji_mutes';
import { normalizeStatus, normalizeStatusTranslation } from '../../actions/importer/normalizer';
import emojify from '../../features/emoji/emoji';
import { hashtagMenuStoredIdentity, hashtagMenuStoredName } from '../../features/emoji/hashtag_menu_names';
import { resetEmojiMuteTextForTests } from '../../features/emoji/emoji_mute_text';
import { resetEmojiActionsBusForTests, setEmojiActionsListener } from '../../features/emoji/emoji_actions/bus';
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

  it('keeps the original hashtag for the menu while the label stays projected', () => {
    const native = '👌';
    const href = `https://example.com/tags/${encodeURIComponent(`party${native}`)}`;
    const status = buildStatus({
      contentHtml: `<p><a href="${href}" class="mention hashtag" rel="tag">#<span>party${native}</span></a></p>`,
      search_index: `party${native}`,
    });
    const store = createStore(reducer, fromJS({
      server: { translationLanguages: { items: { en: ['ja'] } } },
      emojiMutes: { revision: '1', display: 'suppress', rules: [] },
    }));
    const { container } = render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );
    const link = container.querySelector('a.mention.hashtag');

    expect(link.textContent).toBe('#party◻');
    expect(link.outerHTML).not.toContain(native);
    expect(link.getAttribute('data-menu-hashtag')).not.toContain(native);
    expect(hashtagMenuStoredName(link)).toBe(`party${native}`);
    expect(link.getAttribute('href')).toBe(href);
  });

  it('keeps a singular /tag/ URL as the menu identity while the label stays projected', () => {
    const native = '👍';
    const tag = `party${native}`;
    const href = `https://remote.example/tag/${encodeURIComponent(tag)}`;
    const status = buildStatus({
      contentHtml: emojify(`<p><a href="${href}" class="mention hashtag" rel="tag">#<span>${tag}</span></a></p>`, {}, ''),
      tags: [{ name: tag, url: href }],
    });
    const mount = display => fromJS({
      server: { translationLanguages: { items: { en: ['ja'] } } },
      emojiMutes: {
        revision: '1',
        display,
        availability: display === 'show' ? 'temporary_ignore' : 'enabled',
        rules: display === 'apply' ? [{
          id: 'm-up',
          revision: '1',
          emoji: { kind: 'unicode', native },
          replacement: '[up]',
          effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
        }] : [],
      },
    });
    const renderAt = display => {
      const view = render(
        <Provider store={createStore(reducer, mount(display))}>
          <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
        </Provider>,
      );
      const link = view.container.querySelector('a.mention.hashtag');

      return { view, link };
    };

    const suppressed = renderAt('suppress');

    expect(suppressed.link.textContent).toBe(`#party${'\u25FB'}`);
    expect(suppressed.link.outerHTML).not.toContain(native);
    expect(hashtagMenuStoredName(suppressed.link)).toBe(tag);
    expect(suppressed.link.getAttribute('aria-label') || '').not.toContain(native);
    suppressed.view.unmount();

    const applied = renderAt('apply');

    expect(applied.link.textContent).toBe('#party[up]');
    expect(applied.link.getAttribute('data-menu-hashtag')).toBe(tag);
    applied.view.unmount();

    const shown = renderAt('show');

    expect(shown.link.querySelector('img').getAttribute('alt')).toBe(native);
    expect(shown.link.getAttribute('data-menu-hashtag')).toBe(tag);
    shown.view.unmount();
  });

  it('does not store the projected label when the href has no tag segment', () => {
    const native = '👍';
    const tag = `party${native}`;
    const href = 'https://remote.example/users/alice';
    const status = buildStatus({
      contentHtml: `<p><a href="${href}" class="mention hashtag" rel="tag">#<span>${tag}</span></a></p>`,
      tags: [{ name: tag, url: href }],
    });
    const { container } = render(
      <Provider
        store={createStore(reducer, fromJS({
          server: { translationLanguages: { items: { en: ['ja'] } } },
          emojiMutes: { revision: '1', display: 'suppress', rules: [] },
        }))}
      >
        <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );
    const link = container.querySelector('a.mention.hashtag');

    expect(link.textContent).toBe(`#party${'\u25FB'}`);
    expect(link.outerHTML).not.toContain(native);
    expect(hashtagMenuStoredName(link)).toBe(tag);
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

  it('shows one emoji generation in the original, translation, and bilingual body', () => {
    const base = {
      id: '1',
      account: { id: 'a', acct: 'alice' },
      content: '<p>Hello :blob:</p>',
      spoiler_text: '',
      media_attachments: [],
      mentions: [],
      tags: [],
      visibility: 'public',
      sensitive: false,
      language: 'en',
      url: 'https://example.test/1',
      uri: 'https://example.test/1',
      updated_at: '2026-11-10T00:00:00.000Z',
      quote: null,
    };
    const previousEmoji = { ...emoji, id: '10', url: 'https://cdn.example/10.svg', static_url: 'https://cdn.example/10.png' };
    const nextEmoji = { ...emoji, id: '11', url: 'https://cdn.example/11.svg', static_url: 'https://cdn.example/11.png' };
    const first = normalizeStatus({ ...base, emojis: [previousEmoji] }, null, '');
    const translated = normalizeStatusTranslation({
      content: '<p>Bonjour :blob:</p>',
      spoiler_text: '',
      language: 'ja',
      detected_source_language: 'en',
      provider: 'test',
    }, fromJS(first), '');
    const second = normalizeStatus({ ...base, emojis: [nextEmoji] }, fromJS(first).set('translation', fromJS(translated)).set('translationMode', 'bilingual'), '');
    const view = mode => buildStatus({
      contentHtml: second.contentHtml,
      emojis: [nextEmoji],
      translationMode: mode,
      translation: second.translation,
    });
    const mute11 = muteRule({
      emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' },
      replacement: '[new]',
    });
    const mute10 = muteRule({
      emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' },
      replacement: '[old]',
    });

    const original = renderStatus(view('original'), [mute11]);
    const translatedView = renderStatus(view('translated'), [mute11]);
    const bilingual = renderStatus(view('bilingual'), [mute11]);
    const staleMute = renderStatus(view('bilingual'), [mute10]);

    expect(original.container.querySelector('.status__content__text').textContent).toBe('Hello [new]');
    expect(translatedView.container.querySelector('.status__content__text').textContent).toBe('Bonjour [new]');
    expect(bilingual.container.querySelector('.status-translation-pair__source').textContent).toBe('Hello [new]');
    expect(bilingual.container.querySelector('.status-translation-pair__target').textContent).toBe('Bonjour [new]');
    expect(original.container.querySelector('img')).toBeNull();
    expect(translatedView.container.querySelector('img')).toBeNull();
    expect(bilingual.container.querySelector('img')).toBeNull();
    expect(staleMute.container.querySelectorAll('img.custom-emoji').length).toBeGreaterThan(0);
    expect(staleMute.container.textContent).not.toContain('[old]');
    expect(staleMute.container.innerHTML).not.toContain('data-emoji-id="10"');
  });

  it('hides the muted emoji in a shared link and keeps the other image', () => {
    const mixed = '<p><a class="custom-emoji-url-link" href="https://remote.example/emoji/blob" data-shortcode="blob" data-domain="remote.example" title=":blob:" aria-label="blob"><img draggable="false" class="emojione custom-emoji" alt=":blob:" title="blob" src="https://cdn.example/blob.svg" data-shortcode="blob" data-domain="remote.example" data-original="https://cdn.example/blob.svg" data-static="https://cdn.example/blob.png"><img draggable="false" class="emojione custom-emoji" alt=":other:" title="other" src="https://cdn.example/other.svg" data-shortcode="other" data-domain="other.example" data-original="https://cdn.example/other.svg" data-static="https://cdn.example/other.png"></a><a class="custom-emoji-url-link" href="https://example.test/emoji/cat" data-shortcode="cat" title="category" aria-label="See the category"><img draggable="false" class="emojione custom-emoji" alt=":cat:" title="cat" src="https://cdn.example/4.svg" data-shortcode="cat" data-domain="" data-emoji-id="4" data-original="https://cdn.example/4.svg" data-static="https://cdn.example/4.png"></a></p>';
    const status = buildStatus({
      contentHtml: mixed,
      search_index: 'emoji',
      emojis: [],
    });
    const { container, store } = renderStatus(status, [
      muteRule({
        emoji: { kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' },
        replacement: '[safe]',
      }),
      muteRule({
        id: 'm4',
        emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '4', shortcode: 'cat' },
        replacement: '[cat]',
      }),
    ]);
    const blobLink = container.querySelector('a[data-domain="remote.example"]');
    const catLink = container.querySelector('a[data-shortcode="cat"]');

    expect(blobLink.querySelector('[data-shortcode="blob"]')).toBeNull();
    expect(blobLink.querySelector('[data-shortcode="other"]').getAttribute('src')).toBe('https://cdn.example/other.svg');
    expect(blobLink.getAttribute('title')).toBe('[safe]');
    expect(blobLink.hasAttribute('aria-label')).toBe(false);
    expect(blobLink.getAttribute('data-shortcode')).toBe('blob');
    expect(catLink.querySelector('img')).toBeNull();
    expect(catLink.getAttribute('title')).toBe('category');
    expect(catLink.getAttribute('aria-label')).toBe('See the category');
    expect(status.get('contentHtml')).toBe(mixed);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_APPLY, revision: '9', mutes: [] });
    });

    expect(container.querySelector('a[data-domain="remote.example"] [data-shortcode="blob"]')).not.toBeNull();
    expect(container.querySelector('a[data-domain="remote.example"] [data-shortcode="other"]')).not.toBeNull();
    expect(container.querySelector('a[data-domain="remote.example"]').getAttribute('title')).toBe('Link to :@blob: in @remote.example');
    expect(container.querySelector('a[data-shortcode="cat"] img')).not.toBeNull();
    expect(container.querySelector('a[data-shortcode="cat"]').getAttribute('title')).toBe('Link to :@cat:');
  });

  it('keeps a different local id and a longer unicode sequence', () => {
    const thumb = '👍';
    const skin = '\u{1F44D}\u{1F3FB}';
    const mixed = `<p><a class="custom-emoji-url-link" href="https://example.test/emoji/blob" data-shortcode="blob" title=":blob:" aria-label="blob"><img draggable="false" class="emojione custom-emoji" alt=":blob:" src="https://cdn.example/10.svg" data-shortcode="blob" data-domain="" data-emoji-id="10" data-original="https://cdn.example/10.svg" data-static="https://cdn.example/10.png"><img draggable="false" class="emojione custom-emoji" alt=":blob:" src="https://cdn.example/11.svg" data-shortcode="blob" data-domain="" data-emoji-id="11" data-original="https://cdn.example/11.svg" data-static="https://cdn.example/11.png"></a><a href="https://example.test/react" title="reaction ${thumb}" aria-label="thumbs up ${thumb}"><img class="emojione" alt="${thumb}" src="/emoji/thumb.svg"></a><a href="https://example.test/keep" title="category" aria-label="keep ${skin}"><img class="emojione" alt="${skin}" src="/emoji/skin.svg"></a></p>`;
    const status = buildStatus({ contentHtml: mixed, search_index: 'emoji', emojis: [] });
    const { container, store } = renderStatus(status, [
      muteRule({
        emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' },
        replacement: '[id10]',
      }),
      muteRule({
        id: 'm-thumb',
        emoji: { kind: 'unicode', native: thumb },
        replacement: '[ok]',
      }),
    ]);
    const localLink = container.querySelector('a[href="https://example.test/emoji/blob"]');
    const unicodeLink = container.querySelector('a[href="https://example.test/react"]');
    const keptLink = container.querySelector('a[href="https://example.test/keep"]');

    expect(localLink.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(localLink.querySelector('[data-emoji-id="11"]')).not.toBeNull();
    expect(localLink.getAttribute('title')).toBe('[id10]');
    expect(localLink.hasAttribute('aria-label')).toBe(false);
    expect(localLink.getAttribute('href')).toBe('https://example.test/emoji/blob');
    expect(unicodeLink.querySelector('img')).toBeNull();
    expect(unicodeLink.getAttribute('title')).toBe('reaction [ok]');
    expect(unicodeLink.getAttribute('aria-label')).toBe('thumbs up [ok]');
    expect(keptLink.getAttribute('title')).toBe('category');
    expect(keptLink.getAttribute('aria-label')).toBe(`keep ${skin}`);
    expect(keptLink.querySelector('img').getAttribute('alt')).toBe(skin);
    expect(status.get('contentHtml')).toBe(mixed);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_APPLY, revision: '10', mutes: [] });
    });

    expect(container.querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(container.querySelector('[data-emoji-id="11"]')).not.toBeNull();
    expect(container.querySelector('a[href="https://example.test/emoji/blob"]').getAttribute('title')).toBe('Link to :@blob:');
    expect(container.querySelector('a[href="https://example.test/react"] img').getAttribute('alt')).toBe(thumb);
  });
});

const assertNoEmojiLeak = container => {
  const html = container.innerHTML;

  expect(container.querySelector('img, source, picture')).toBeNull();
  expect(html).not.toContain('srcset');
  expect(html).not.toContain('cdn.example');
  expect(html).not.toContain('/emoji/');
  expect(html).not.toContain('👌');
  expect(html).not.toContain(':blob:');
  expect(html).not.toContain('data-emoji-id');
  expect(html).not.toContain('data-shortcode');
};

describe('StatusContent unverified emoji suppression', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  const remote = {
    id: '20',
    shortcode: 'blob',
    url: 'https://cdn.example/remote.svg',
    static_url: 'https://cdn.example/remote.png',
    domain: 'remote.example',
  };
  const mixedHtml = `${emojify('<p>Local :blob: 👌</p>', { ':blob:': emoji }, '')}${emojify('<p>Remote :blob:</p>', { ':blob:': remote }, 'remote.example')}<a href="https://example.test/keep" title="👌" aria-label="👌">keep</a>`;
  const suppressedState = {
    revision: null,
    appliedRevision: null,
    phase: 'error',
    failure: 'unavailable',
    availability: 'enabled',
    display: 'suppress',
    rules: [],
  };

  const renderMixed = (emojiState, props = {}) => {
    const status = buildStatus({
      contentHtml: mixedHtml,
      spoiler_text: 'Secret :blob: 👌',
      spoilerHtml: emojify('Secret :blob: 👌', { ':blob:': emoji }, ''),
      translationMode: 'bilingual',
      translation: {
        contentHtml: emojify('<p>訳 :blob: 👌</p>', { ':blob:': emoji }, ''),
        spoilerHtml: emojify('警告 👌', {}, ''),
        spoiler_text: '警告 👌',
        language: 'ja',
        detected_source_language: 'en',
        provider: 'test',
      },
    });
    const store = createStore(reducer, baseState([]).set('emojiMutes', fromJS(emojiState)));
    const view = render(
      <Provider store={store}>
        <StatusContent status={status} quote onTranslate={jest.fn()} onClick={jest.fn()} {...props} />
      </Provider>,
    );

    return { ...view, store, status };
  };

  it('omits unicode, local, and remote emoji from the real connected body on the first frame', () => {
    const { container, status } = renderMixed(suppressedState);

    assertNoEmojiLeak(container);
    expect(container.textContent).toContain('◻');
    expect(container.querySelector('a[href="https://example.test/keep"]').getAttribute('title')).toBe('◻');
    expect(container.querySelector('a[href="https://example.test/keep"]').getAttribute('aria-label')).toBe('◻');
    expect(status.get('contentHtml')).toContain('cdn.example');
    expect(status.get('contentHtml')).toContain('👌');
  });

  it('restores rules after a successful document, then shows every emoji after ignore and off', () => {
    const { container, store } = renderMixed(suppressedState);

    assertNoEmojiLeak(container);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '4',
        availability: 'enabled',
        mutes: [muteRule(), unicodeRule],
      });
    });

    expect(container.textContent).toContain('［絵文字］');
    expect(container.textContent).toContain('[ok]');
    expect(container.textContent).not.toContain('👌');
    expect(container.innerHTML).not.toContain('cdn.example/blob');
    expect(container.querySelector('img.custom-emoji').getAttribute('src')).toContain('cdn.example/remote');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(container.querySelector('img.custom-emoji')).not.toBeNull();
    expect(container.innerHTML).toContain('👌');
    expect(container.querySelector('a[href="https://example.test/keep"]').getAttribute('title')).toBe('👌');

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '5',
        availability: 'enabled',
        mutes: [muteRule()],
      });
    });
    expect(container.innerHTML).not.toContain('cdn.example/blob');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });

    expect(container.querySelector('img.custom-emoji')).not.toBeNull();
    expect(container.innerHTML).toContain('cdn.example/blob');
    expect(container.innerHTML).toContain('👌');
  });

  it('suppresses again when a stream revision is newer than the applied document', () => {
    const { container, store } = renderMixed({
      revision: '3',
      appliedRevision: '3',
      phase: 'ready',
      failure: null,
      availability: 'enabled',
      display: 'apply',
      rules: [muteRule()],
    });

    expect(container.innerHTML).not.toContain('cdn.example/blob');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '9' });
    });

    assertNoEmojiLeak(container);
  });

  it('keeps image ranges when a tag route or status.tags supplies the same name', () => {
    const custom = '<img class="emojione custom-emoji" alt=":blob:" src="https://cdn.example/blob.svg">';
    const href = 'https://remote.example/tags/party%3Ablob%3A';
    const tagged = `<a href="${href}" class="mention hashtag" rel="tag" title="#party:blob:" aria-label="tag party:blob:">#<span>party${custom}</span></a>`;
    const source = `<p>See ${tagged} stays</p>`;
    const spoiler = `<p>CW ${tagged} note</p>`;
    const target = `<p>訳 <a href="${href}" class="mention hashtag" rel="tag">#<span>パーティー</span></a> です</p>`;
    const targetSpoiler = `<p>警告 <a href="${href}" class="mention hashtag" rel="tag">#<span>秘密</span></a></p>`;
    const suppressState = fromJS({
      server: { translationLanguages: { items: { en: ['ja'] } } },
      emojiMutes: {
        revision: '1',
        appliedRevision: '1',
        phase: 'stale',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'suppress',
      },
    });
    const mount = status => {
      const view = render(
        <Provider store={createStore(reducer, suppressState)}>
          <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
        </Provider>,
      );

      return view;
    };
    const expectConcealed = link => {
      expect(link.getAttribute('data-menu-hashtag') || '').not.toContain(':blob:');
      expect(link.hasAttribute('data-menu-hashtag-token')).toBe(true);
      expect(hashtagMenuStoredIdentity(link)).toEqual(expect.objectContaining({ name: 'party:blob:', imageRanges: [[5, 11]] }));
      expect(link.getAttribute('title') || '').not.toContain(':blob:');
      expect(link.getAttribute('aria-label') || '').not.toContain(':blob:');
      expect(link.outerHTML).not.toContain('cdn.example/blob.svg');
    };

    const withTags = mount(buildStatus({
      contentHtml: source,
      spoilerHtml: spoiler,
      spoiler_text: 'CW note',
      tags: [{ name: 'party:blob:', url: href }],
    }));

    fireEvent.click(withTags.container.querySelector('button'));
    expectConcealed(withTags.container.querySelector('.status__content__text a.mention.hashtag'));
    expectConcealed(Array.from(withTags.container.querySelectorAll('a.mention.hashtag')).find(link => (
      link.closest('p') && link.closest('p').textContent.includes('CW')
    )));
    withTags.unmount();

    const withoutTags = mount(buildStatus({
      contentHtml: source,
      tags: [],
    }));

    expectConcealed(withoutTags.container.querySelector('a.mention.hashtag'));
    withoutTags.unmount();

    const translated = mount(buildStatus({
      contentHtml: source,
      spoilerHtml: spoiler,
      spoiler_text: 'CW note',
      tags: [{ name: 'party:blob:', url: href }],
      language: 'en',
      translationMode: 'translated',
      translation: {
        contentHtml: target,
        spoilerHtml: targetSpoiler,
        language: 'ja',
        detected_source_language: 'en',
        requested_source_language: 'en',
        requested_target_language: 'ja',
        provider: 'test',
      },
    }));

    fireEvent.click(translated.container.querySelector('button'));
    const translatedBody = translated.container.querySelector('.status__content__text a.mention.hashtag');
    const translatedCw = Array.from(translated.container.querySelectorAll('a.mention.hashtag')).find(link => link.textContent.includes('秘密'));

    expect(translatedBody.textContent).toContain('パーティー');
    expectConcealed(translatedBody);

    const plainHref = 'https://example.com/tags/party';
    const imageOnly = mount(buildStatus({
      contentHtml: `<p><a href="${plainHref}" class="mention hashtag" rel="tag">#<span>party</span></a></p>`,
      tags: [{ name: 'party', url: plainHref }],
      language: 'en',
      translationMode: 'translated',
      translation: {
        contentHtml: `<p><a href="${plainHref}" class="mention hashtag" rel="tag" title="Details: :blob:" aria-label="Details: :blob:">#${custom}パーティー</a></p>`,
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'en',
        requested_source_language: 'en',
        requested_target_language: 'ja',
        provider: 'test',
      },
    }));
    const imageLink = imageOnly.container.querySelector('.status__content__text a.mention.hashtag');

    expect(imageLink.getAttribute('data-menu-hashtag')).toBe('party');
    expect(hashtagMenuStoredName(imageLink)).toBe('party');
    expect(imageLink.getAttribute('title') || '').not.toContain(':blob:');
    expect(imageLink.getAttribute('aria-label') || '').not.toContain(':blob:');
    expect(imageLink.outerHTML).not.toContain(':blob:');
    expect(imageLink.outerHTML).not.toContain('cdn.example/blob.svg');
    imageOnly.unmount();
    expect(translatedCw.textContent).toContain('秘密');
    expectConcealed(translatedCw);
    translated.unmount();

    const mismatchHref = 'https://remote.example/tags/other';
    const gardenHref = 'https://remote.example/tags/garden';
    const mismatch = mount(buildStatus({
      contentHtml: `<p><a href="${mismatchHref}" class="mention hashtag" rel="tag">#<span>party${custom}</span></a> <a href="${gardenHref}" class="mention hashtag" rel="tag">#<span>garden</span></a></p>`,
      tags: [{ name: 'other', url: mismatchHref }],
    }));
    const mismatched = mismatch.container.querySelector(`a[href="${mismatchHref}"]`);
    const garden = mismatch.container.querySelector(`a[href="${gardenHref}"]`);

    expect(mismatched.getAttribute('data-menu-hashtag')).toBe('other');
    expect(mismatched.hasAttribute('data-menu-hashtag-token')).toBe(false);
    expect(hashtagMenuStoredIdentity(mismatched).imageRanges).toEqual([]);
    expect(garden.getAttribute('data-menu-hashtag')).toBe('garden');
    expect(hashtagMenuStoredIdentity(garden).imageRanges).toEqual([]);
    mismatch.unmount();

    const shared = 'https://remote.example/topics/shared';
    const ambiguous = mount(buildStatus({
      contentHtml: `<p><a href="${shared}" class="mention hashtag" rel="tag">#<span>party${custom}</span></a> <a href="${shared}" class="mention hashtag" rel="tag">#<span>garden</span></a></p>`,
      tags: [{ name: 'party:blob:', url: shared }],
    }));
    const links = ambiguous.container.querySelectorAll(`a[href="${shared}"]`);

    expectConcealed(links[0]);
    expect(hashtagMenuStoredIdentity(links[1]).imageRanges).toEqual([]);
    ambiguous.unmount();

    const cased = `<a href="${href}" class="mention hashtag" rel="tag" title="#Party:blob:" aria-label="tag Party:blob:">#<span>Party${custom}</span></a>`;
    const casedView = mount(buildStatus({
      contentHtml: `<p>See ${cased} stays</p>`,
      spoilerHtml: `<p>CW ${cased} note</p>`,
      spoiler_text: 'CW note',
      tags: [{ name: 'party:blob:', url: href }],
    }));

    fireEvent.click(casedView.container.querySelector('button'));
    const casedBody = casedView.container.querySelector('.status__content__text a.mention.hashtag');
    const casedCw = Array.from(casedView.container.querySelectorAll('a.mention.hashtag')).find(link => (
      link.closest('p') && link.closest('p').textContent.includes('CW')
    ));

    expectConcealed(casedBody);
    expect(casedBody.getAttribute('title')).toBe(`#Party${'\u25FB'}`);
    expectConcealed(casedCw);
    casedView.unmount();

    const ligature = '\uFB01le';
    const fileHref = `https://remote.example/tags/${encodeURIComponent('file:blob:')}`;
    const folded = mount(buildStatus({
      contentHtml: `<p><a href="${fileHref}" class="mention hashtag" rel="tag" title="#${ligature}:blob:">#<span>${ligature}${custom}</span></a></p>`,
      tags: [{ name: 'file:blob:', url: fileHref }],
    }));
    const foldedLink = folded.container.querySelector('a.mention.hashtag');

    expect(foldedLink.getAttribute('data-menu-hashtag') || '').not.toContain(':blob:');
    expect(foldedLink.getAttribute('title') || '').not.toContain(':blob:');
    expect(hashtagMenuStoredName(foldedLink)).toBe('file:blob:');
    folded.unmount();

    const composed = 'e\u0301:blob::blob:';
    const canonical = '\u00e9:blob::blob:';
    const composedHref = `https://remote.example/tags/${encodeURIComponent(canonical)}`;
    const composedView = mount(buildStatus({
      contentHtml: `<p><a href="${composedHref}" class="mention hashtag" rel="tag" title="#${canonical}">#<span>${composed.slice(0, 2)}${custom}:blob:</span></a></p>`,
      tags: [{ name: canonical, url: composedHref }],
    }));
    const composedLink = composedView.container.querySelector('a.mention.hashtag');

    expect(composedLink.getAttribute('title')).toBe(`#\u00e9${'\u25FB'}:blob:`);
    expect(hashtagMenuStoredName(composedLink)).toBe(canonical);
    composedView.unmount();

    const sharedTag = 'https://remote.example/tags/party%3Ablob%3A';
    const mixedSource = `<p><a href="${sharedTag}" class="mention hashtag" rel="tag">#<span>party${custom}</span></a> <a href="${sharedTag}" class="mention hashtag" rel="tag">#<span>party:blob:</span></a></p>`;
    const mixedTarget = `<p><a href="${sharedTag}" class="mention hashtag" rel="tag" title="#party:blob:" aria-label="tag party:blob:">#<span>訳語</span></a></p>`;
    const mixedCw = `<p><a href="${sharedTag}" class="mention hashtag" rel="tag" title="#party:blob:">#<span>警告</span></a></p>`;
    const mixed = mount(buildStatus({
      contentHtml: mixedSource,
      spoilerHtml: `<p>CW <a href="${sharedTag}" class="mention hashtag" rel="tag">#<span>party${custom}</span></a> <a href="${sharedTag}" class="mention hashtag" rel="tag">#<span>party:blob:</span></a></p>`,
      spoiler_text: 'CW note',
      tags: [{ name: 'party:blob:', url: sharedTag }],
      language: 'en',
      translationMode: 'translated',
      translation: {
        contentHtml: mixedTarget,
        spoilerHtml: mixedCw,
        language: 'ja',
        detected_source_language: 'en',
        requested_source_language: 'en',
        requested_target_language: 'ja',
        provider: 'test',
      },
    }));

    fireEvent.click(mixed.container.querySelector('button'));
    const mixedBody = mixed.container.querySelector('.status__content__text a.mention.hashtag');
    const mixedWarning = Array.from(mixed.container.querySelectorAll('a.mention.hashtag')).find(link => link.textContent.includes('警告'));

    expect(mixedBody.textContent).toContain('訳語');
    expect(mixedBody.outerHTML).not.toContain(':blob:');
    expect(mixedBody.getAttribute('title') || '').not.toContain(':blob:');
    expect(mixedBody.getAttribute('aria-label') || '').not.toContain(':blob:');
    expect(hashtagMenuStoredName(mixedBody)).toBe('party:blob:');
    expect(mixedWarning.outerHTML).not.toContain(':blob:');
    expect(hashtagMenuStoredName(mixedWarning)).toBe('party:blob:');
    mixed.unmount();
  });

  it('keeps each shared href on its original occurrence', () => {
    const href = 'https://example.test/topics/common';
    const html = `<p><a href="${href}">plain</a> <a href="${href}">#👍alpha</a> <a href="${href}" class="mention hashtag" rel="tag">#<span>beta</span></a></p>`;
    const status = buildStatus({ contentHtml: html, tags: [] });
    const store = createStore(reducer, baseState([]).set('emojiMutes', fromJS(suppressedState)));
    const view = render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );
    const links = Array.from(view.container.querySelectorAll(`a[href="${href}"]`));

    expect(hashtagMenuStoredName(links[1])).toBe('👍alpha');
    expect(hashtagMenuStoredName(links[2])).toBe('beta');
    expect(links[0].hasAttribute('data-menu-hashtag')).toBe(false);
    view.unmount();
  });

  it('projects the source label when the tag URL names a different tag', () => {
    const href = 'https://example.test/tags/other';
    const custom = '<img class="emojione custom-emoji" alt=":blob:" src="https://cdn.example/blob.svg">';
    const html = `<p><a href="${href}" class="mention hashtag" rel="tag" title="#party:blob:" aria-label="#party:blob:">#<span>party${custom}</span></a></p>`;
    const store = createStore(reducer, baseState([]).set('emojiMutes', fromJS(suppressedState)));
    const view = render(
      <Provider store={store}>
        <StatusContent status={buildStatus({ contentHtml: html, tags: [] })} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );
    const link = view.container.querySelector('a.mention.hashtag');

    expect(hashtagMenuStoredName(link)).toBe('other');
    expect(link.getAttribute('data-menu-hashtag') || '').not.toContain(':blob:');
    expect(link.getAttribute('title') || '').not.toContain(':blob:');
    expect(link.getAttribute('aria-label') || '').not.toContain(':blob:');
    expect(link.getAttribute('title') || '').toContain('\u25FB');
    view.unmount();
  });

  it('restores a translated hashtag title from the target HTML', () => {
    const href = 'https://example.test/tags/party%3Ablob%3A';
    const custom = '<img class="emojione custom-emoji" alt=":blob:" src="https://cdn.example/blob.svg">';
    const target = `<p><a href="${href}" class="mention hashtag" rel="tag" title="#party:blob:" aria-label="tag party:blob:">#<span>訳</span></a></p>`;
    const store = createStore(reducer, baseState([]).set('emojiMutes', fromJS(suppressedState)));
    const view = render(
      <Provider store={store}>
        <StatusContent
          status={buildStatus({
            contentHtml: `<p><a href="${href}" class="mention hashtag" rel="tag">#<span>party${custom}</span></a></p>`,
            language: 'en',
            translationMode: 'translated',
            translation: {
              contentHtml: target,
              language: 'ja',
              detected_source_language: 'en',
              requested_source_language: 'en',
              requested_target_language: 'ja',
              provider: 'test',
            },
          })}
          onTranslate={jest.fn()}
          onClick={jest.fn()}
        />
      </Provider>,
    );

    fireEvent.click(view.container.querySelector('button'));
    const link = view.container.querySelector('.status__content__text a.mention.hashtag');

    expect(link.getAttribute('title') || '').not.toContain(':blob:');
    expect(hashtagMenuStoredName(link)).toBe('party:blob:');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    const restored = view.container.querySelector('.status__content__text a.mention.hashtag');

    expect(restored.getAttribute('title')).toBe('#party:blob:');
    expect(restored.getAttribute('aria-label')).toBe('tag party:blob:');
    expect(hashtagMenuStoredName(restored)).toBe('party:blob:');
    view.unmount();
  });
});

describe('inline emoji actions from a status body', () => {
  it('opens the common menu on an emoji click, using its stable local id', () => {
    resetEmojiActionsBusForTests();
    const received = [];
    const detach = setEmojiActionsListener(detail => received.push(detail));
    const { container } = renderStatus(buildStatus(), []);
    const emojiNode = container.querySelector('img.custom-emoji');

    expect(emojiNode.dataset.emojiActions).toBe('1');
    fireEvent.click(emojiNode);
    expect(received).toHaveLength(1);
    expect(received[0].reference).toEqual({
      kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob',
    });
    expect(received[0].source).toBe('inline_status');
    expect(received[0].status_id).toBe('s1');

    detach();
    resetEmojiActionsBusForTests();
  });
});
