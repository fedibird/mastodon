/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_DISABLE, EMOJI_MUTES_IGNORE, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

jest.mock('react-intl', () => {
  const React = require('react');

  const FormattedMessage = ({ defaultMessage, values }) => {
    if (!values) {
      return defaultMessage;
    }

    const parts = String(defaultMessage).split(/\{(\w+)\}/);
    const nodes = [];

    for (let index = 0; index < parts.length; index += 1) {
      nodes.push(index % 2 === 0 ? parts[index] : values[parts[index]]);
    }

    return React.createElement(React.Fragment, null, ...nodes);
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => Component,
    FormattedMessage,
    FormattedNumber: ({ value }) => String(value),
  };
});

jest.mock('mastodon/components/blurhash', () => {
  const React = require('react');

  return function Blurhash ({ hash }) {
    return React.createElement('canvas', { 'data-testid': 'blurhash', 'data-hash': hash });
  };
});

jest.mock('mastodon/components/relative_timestamp', () => () => null);

import Story from '../story';

const THUMB = '👍';
const FAMILY = '👨‍👩‍👧‍👧';
const PLACEHOLDER = '\u25FB';

const rule = (emoji, replacement) => ({
  id: `rule-${replacement}`,
  emoji,
  replacement,
  effects: {
    replace_in_text: true,
    hide_reactions: false,
    reject_reactions_to_own_posts: false,
    hide_in_picker: false,
  },
});

const reducer = (state = ImmutableMap(), action) => state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action));

const storyProps = (overrides = {}) => ({
  url: 'https://news.example/story',
  title: `Launch ${THUMB} ${FAMILY} :blob:`,
  lang: 'ja',
  publisher: `Paper ${THUMB}`,
  author: `Ada ${THUMB}`,
  sharedTimes: 3,
  thumbnail: 'https://cdn.example/thumb.jpg',
  thumbnailDescription: `Photo ${THUMB} :blob:`,
  blurhash: 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
  expanded: true,
  ...overrides,
});

const renderStory = (store, props = storyProps()) => {
  const privacy = document.createElement('div');
  const mount = document.createElement('div');

  privacy.className = 'emoji-mutes-privacy-portal';
  privacy.appendChild(mount);
  document.body.appendChild(privacy);

  const view = render(
    <Provider store={store}>
      <Story {...props} />
    </Provider>,
    { container: mount },
  );

  return { ...view, props };
};

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes, availability: 'enabled' });
  });
};

const image = container => container.querySelector('img');

describe('explore story emoji mute', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
    document.body.innerHTML = '';
  });

  it('projects the readable card text and keeps the link, image, language, and blurhash', () => {
    const store = createStore(reducer);
    const { container } = renderStory(store);
    const link = container.querySelector('a.story');

    link.focus();
    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[ok]'),
      rule({ kind: 'unicode', native: FAMILY }, '[family]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
    ]);

    expect(container.querySelector('.story__details__title').textContent).toBe('Launch [ok] [family] :blob:');
    expect(container.querySelector('.story__details__publisher span').textContent).toBe('Paper [ok]');
    expect(container.querySelector('.story__details__author').textContent).toBe('Ada [ok]');
    expect(image(container).getAttribute('alt')).toBe('Photo [ok] :blob:');
    expect(image(container).getAttribute('title')).toBe('Photo [ok] :blob:');
    expect(image(container).getAttribute('src')).toBe('https://cdn.example/thumb.jpg');
    expect(image(container).getAttribute('lang')).toBe('ja');
    expect(container.querySelector('.story__details__title').getAttribute('lang')).toBe('ja');
    expect(link.getAttribute('href')).toBe('https://news.example/story');
    expect(container.querySelector('[data-testid="blurhash"]').getAttribute('data-hash')).toBe('LEHV6nWB2yk8pyo0adR*.7kCMdnj');
    expect(document.activeElement).toBe(link);
    expect(container.innerHTML).not.toContain('data-emoji-mute');
    expect(container.innerHTML).not.toContain(THUMB);
  });

  it('keeps an empty description empty and hides the preview after the image loads', () => {
    const store = createStore(reducer);
    const { container } = renderStory(store, storyProps({
      thumbnailDescription: THUMB,
      title: 'Plain',
      publisher: 'Paper',
      author: '',
    }));

    apply(store, [rule({ kind: 'unicode', native: THUMB }, '')]);

    expect(image(container).getAttribute('alt')).toBe('');
    expect(image(container).getAttribute('title')).toBe('');
    expect(image(container).getAttribute('alt')).not.toContain(THUMB);

    fireEvent.load(image(container));

    expect(container.querySelector('.story__thumbnail__preview').className).toContain('story__thumbnail__preview--hidden');
    expect(container.querySelector('[data-testid="blurhash"]').getAttribute('data-hash')).toBe('LEHV6nWB2yk8pyo0adR*.7kCMdnj');
  });

  it('lets the guard project the mounted card before React and follows a new source', () => {
    const store = createStore(reducer);
    const guard = createUnverifiedEmojiGuard();
    const during = { title: '', alt: '' };
    const privacy = document.createElement('div');
    const mount = document.createElement('div');

    privacy.className = 'emoji-mutes-privacy-portal';
    privacy.appendChild(mount);
    document.body.appendChild(privacy);
    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      during.title = document.querySelector('.story__details__title')?.textContent || '';
      during.alt = document.querySelector('.emoji-mutes-privacy-portal img')?.getAttribute('alt') || '';
    });

    const view = render(
      <Provider store={store}>
        <Story {...storyProps({ title: `Launch ${THUMB}`, thumbnailDescription: `Photo ${THUMB}`, publisher: 'Paper', author: 'Ada' })} />
      </Provider>,
      { container: mount },
    );

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '😺'),
      rule({ kind: 'unicode', native: '😺' }, '[cat]'),
    ], '2');

    expect(view.container.querySelector('.story__details__title').textContent).toBe('Launch 😺');
    expect(view.container.querySelector('img').getAttribute('alt')).toBe('Photo 😺');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      expect(during.title).toBe(`Launch ${PLACEHOLDER}`);
      expect(during.alt).toBe(`Photo ${PLACEHOLDER}`);
      expect(during.title).not.toContain(THUMB);
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        mutes: [
          rule({ kind: 'unicode', native: THUMB }, '😺'),
          rule({ kind: 'unicode', native: '😺' }, '[cat]'),
        ],
        availability: 'enabled',
      });
      expect(during.title).toBe('Launch 😺');
      expect(during.alt).toBe('Photo 😺');
      expect(during.title).not.toContain('[cat]');
      expect(during.alt).not.toContain('[cat]');
    });

    view.rerender(
      <Provider store={store}>
        <Story {...storyProps({
          title: 'Night ✨',
          thumbnailDescription: 'Frame ✨',
          publisher: 'Paper',
          author: 'Ada',
        })}
        />
      </Provider>,
    );

    expect(view.container.querySelector('.story__details__title').textContent).toBe('Night ✨');
    expect(view.container.querySelector('img').getAttribute('alt')).toBe('Frame ✨');
    expect(view.container.querySelector('.story__details__title').textContent).not.toContain(THUMB);
    expect(view.container.querySelector('img').getAttribute('alt')).not.toContain('😺');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(view.container.querySelector('.story__details__title').textContent).toBe('Night ✨');

    apply(store, [rule({ kind: 'unicode', native: '✨' }, '[spark]')], '4');
    expect(view.container.querySelector('.story__details__title').textContent).toBe('Night [spark]');
    expect(view.container.querySelector('img').getAttribute('alt')).toBe('Frame [spark]');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });

    expect(view.container.querySelector('.story__details__title').textContent).toBe('Night ✨');
    expect(view.container.querySelector('img').getAttribute('src')).toBe('https://cdn.example/thumb.jpg');
  });
});
