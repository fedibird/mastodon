/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_FAIL, EMOJI_MUTES_IGNORE } from 'mastodon/actions/emoji_mutes';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';
import { LocalMediaPlayer } from 'mastodon/components/status_media';
import Status from 'mastodon/components/status';

jest.mock('mastodon/initial_state', () => ({
  ...jest.requireActual('mastodon/initial_state'),
  displayMedia: 'show_all',
  autoPlayMedia: false,
  useBlurhash: false,
  me: null,
}));

jest.mock('react-intl', () => {
  const intl = {
    locale: 'en',
    formatMessage: ({ defaultMessage }, values = {}) => String(defaultMessage || '').replace(/\{(\w+)\}/g, (_, key) => (
      values[key] === undefined || values[key] === null ? '' : String(values[key])
    )),
    formatDate: () => 'Jan 1',
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('react-hotkeys', () => ({
  HotKeys: ({ children }) => children,
}));

jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);

const THUMB = '👍';
const PLACEHOLDER = '\u25FB';

const rule = (emoji, replacement, effects = {}) => ({
  id: `rule-${replacement}`,
  emoji,
  replacement,
  effects: {
    replace_in_text: true,
    hide_reactions: false,
    reject_reactions_to_own_posts: false,
    hide_in_picker: false,
    ...effects,
  },
});

const makeStore = () => createStore((state, action) => {
  const current = state || fromJS({
    statuses: {},
    accounts: {},
    relationships: {},
    polls: {},
  });

  return current.set('emojiMutes', emojiMutes(current.get('emojiMutes'), action));
});

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes, availability: 'enabled' });
  });
};

const account = {
  id: '1',
  acct: 'alice',
  username: 'alice',
  display_name: `${THUMB} :blob:`,
  display_name_html: `<img class="emojione" alt="${THUMB}" src="/emoji/thumb.svg"> <img class="emojione custom-emoji" alt=":blob:" data-shortcode="blob" data-domain="" data-emoji-id="10" src="https://cdn.example/10.svg">`,
  url: 'https://example.test/alice',
  avatar: '',
  avatar_static: '',
};

const attachment = (description) => ({
  id: 'm1',
  type: 'image',
  url: 'https://example.test/cat.jpg',
  preview_url: 'https://example.test/cat-small.jpg',
  description,
  meta: { focus: { x: 0, y: 0 } },
});

const statusFor = (description, extra = {}) => fromJS({
  id: 's1',
  account,
  content: 'hello',
  contentHtml: '<p>hello</p>',
  visibility: 'public',
  created_at: '2026-11-18T00:00:00.000Z',
  media_attachments: [attachment(description)],
  sensitive: false,
  ...extra,
});

const renderTile = (store, status, props = {}) => render(
  <Provider store={store}>
    <Status status={status} layoutMode='media' mediaIndex={0} mediaVisibility='show_all' {...props} />
  </Provider>,
);

describe('emoji mute media tile labels', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('projects a written ALT, keeps a shortcode, and restores from the raw description', () => {
    const store = makeStore();
    const description = `Tile ${THUMB} :blob:`;
    const status = statusFor(description);
    const { container } = renderTile(store, status);
    const image = container.querySelector('img');

    expect(image.getAttribute('alt')).toBe(description);
    expect(image.closest('button').getAttribute('aria-label')).toBe(description);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[ok]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
    ]);

    expect(container.querySelector('img')).toBe(image);
    expect(image.getAttribute('alt')).toBe('Tile [ok] :blob:');
    expect(image.closest('button').getAttribute('aria-label')).toBe('Tile [ok] :blob:');
    expect(image.outerHTML).not.toContain('data-emoji-mute');
    expect(status.getIn(['media_attachments', 0, 'description'])).toBe(description);

    fireEvent.click(container.querySelector('.media-gallery__alt__label'));
    const popover = document.querySelector('.media-gallery__alt__popover');

    expect(popover.textContent).toContain('Tile [ok] :blob:');
    expect(popover.textContent).not.toContain(THUMB);
    expect(popover.querySelector('img')).toBeNull();

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_FAIL, failure: 'unavailable' });
    });

    expect(image.getAttribute('alt')).toBe(`Tile ${PLACEHOLDER} :blob:`);
    expect(image.closest('button').getAttribute('aria-label')).toBe(`Tile ${PLACEHOLDER} :blob:`);
    expect(popover.textContent).not.toContain(THUMB);
    expect(popover.textContent).toContain(PLACEHOLDER);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(image.getAttribute('alt')).toBe(description);
    expect(popover.textContent).toContain(THUMB);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[ok]'),
    ], '3');

    expect(image.getAttribute('alt')).toBe('Tile [ok] :blob:');

    apply(store, [], '4');

    expect(image.getAttribute('alt')).toBe(description);
    expect(image.closest('button').getAttribute('aria-label')).toBe(description);
  });

  it('projects a missing ALT from the display-name HTML and keeps the reveal label while concealed', () => {
    const store = makeStore();
    const shown = statusFor(null);
    const hidden = statusFor(`Hidden ${THUMB}`, { sensitive: true });
    const { container } = render(
      <Provider store={store}>
        <React.Fragment>
          <Status status={shown} layoutMode='media' mediaIndex={0} mediaVisibility='show_all' />
          <Status status={hidden} layoutMode='media' mediaIndex={0} mediaVisibility='hide_sensitive' />
        </React.Fragment>
      </Provider>,
    );

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[ok]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
    ]);

    const openButtons = () => container.querySelectorAll('.timeline-media-tile__open');
    const fallback = openButtons()[0].querySelector('img');
    const reveal = openButtons()[1];

    expect(fallback.getAttribute('alt')).toBe('[ok] [local]');
    expect(openButtons()[0].getAttribute('aria-label')).toBe('[ok] [local]');
    expect(reveal.getAttribute('aria-label')).toBe('Reveal media');
    expect(reveal.querySelector('img')).toBeNull();

    fireEvent.click(reveal);

    expect(openButtons()[1].querySelector('img').getAttribute('alt')).toBe('Hidden [ok]');
    expect(openButtons()[1].getAttribute('aria-label')).toBe('Hidden [ok]');
    expect(shown.getIn(['account', 'display_name_html'])).toBe(account.display_name_html);
  });

  it('projects an in-post player alt from the same plain description', () => {
    const store = makeStore();
    const media = fromJS({
      id: 'video',
      type: 'video',
      url: 'https://example.test/clip.mp4',
      preview_url: 'https://example.test/clip.jpg',
      description: `Clip ${THUMB} :blob:`,
    });
    const Player = ({ alt, emojiMuteSource }) => (
      <video data-testid='player' aria-label={alt} data-source={emojiMuteSource} />
    );
    const { container } = render(
      <Provider store={store}>
        <LocalMediaPlayer attachment={media} visible Video={Player} Audio={() => null} />
      </Provider>,
    );

    apply(store, [rule({ kind: 'unicode', native: THUMB }, '[ok]')]);

    const player = container.querySelector('[data-testid="player"]');

    expect(player.getAttribute('aria-label')).toBe('Clip [ok] :blob:');
    expect(player.getAttribute('data-source')).toBe(`Clip ${THUMB} :blob:`);
  });

  it('scrubs a display-name tile before React commits and leaves a written shortcode', () => {
    const store = makeStore();
    const guard = createUnverifiedEmojiGuard();
    let during = null;

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      const buttons = document.querySelectorAll('.timeline-media-tile__open');

      during = {
        fallbackAlt: buttons[0] && buttons[0].querySelector('img') && buttons[0].querySelector('img').getAttribute('alt'),
        fallbackLabel: buttons[0] && buttons[0].getAttribute('aria-label'),
        writtenAlt: buttons[1] && buttons[1].querySelector('img') && buttons[1].querySelector('img').getAttribute('alt'),
      };
    });

    const privacy = document.createElement('div');
    privacy.className = 'emoji-mutes-privacy-portal';
    document.body.appendChild(privacy);

    const named = statusFor(null);
    const written = statusFor('note :blob:');
    render(
      <Provider store={store}>
        <React.Fragment>
          <Status status={named} layoutMode='media' mediaIndex={0} mediaVisibility='show_all' />
          <Status status={written} layoutMode='media' mediaIndex={0} mediaVisibility='show_all' />
        </React.Fragment>
      </Provider>,
      { container: privacy },
    );

    const catRules = [
      rule({ kind: 'unicode', native: '😺' }, '[cat]'),
      rule({ kind: 'unicode', native: THUMB }, '😺'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '😺'),
      rule({ kind: 'custom', scope: 'remote', domain: 'other.test', shortcode: 'blob' }, '[other]'),
    ];

    apply(store, catRules, '2');

    const open = () => privacy.querySelectorAll('.timeline-media-tile__open');

    expect(open()[0].querySelector('img').getAttribute('alt')).toBe('😺 😺');
    expect(open()[0].getAttribute('aria-label')).toBe('😺 😺');
    expect(open()[1].querySelector('img').getAttribute('alt')).toBe('note :blob:');
    expect(named.getIn(['account', 'display_name_html'])).toBe(account.display_name_html);
    expect(written.getIn(['media_attachments', 0, 'description'])).toBe('note :blob:');

    act(() => {
      store.dispatch({ type: 'EMOJI_MUTES_REVISION', revision: '3' });
      expect(during.fallbackAlt).not.toContain(':blob:');
      expect(during.fallbackLabel).not.toContain(':blob:');
      expect(during.fallbackAlt).toBe(during.fallbackLabel);
      expect(during.writtenAlt).toBe('note :blob:');
      store.dispatch({ type: EMOJI_MUTES_APPLY, revision: '3', mutes: catRules, availability: 'enabled' });
      expect(during.fallbackAlt).toBe('😺 😺');
      expect(during.fallbackLabel).toBe('😺 😺');
      expect(during.fallbackAlt).not.toContain('[cat]');
      expect(during.writtenAlt).toBe('note :blob:');
    });

    expect(open()[0].querySelector('img').getAttribute('alt')).toBe('😺 😺');
    expect(open()[0].getAttribute('aria-label')).toBe('😺 😺');
    expect(open()[1].querySelector('img').getAttribute('alt')).toBe('note :blob:');

    act(() => {
      store.dispatch({ type: 'EMOJI_MUTES_REVISION', revision: '4' });
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(open()[0].querySelector('img').getAttribute('alt')).toBe(`${THUMB} :blob:`);
    expect(open()[1].querySelector('img').getAttribute('alt')).toBe('note :blob:');
    privacy.remove();
  });
});
