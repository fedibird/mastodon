/* eslint-disable react/prop-types */

import { act, fireEvent, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import PropTypes from 'prop-types';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import { normalizeAnnouncement } from 'mastodon/actions/importer/normalizer';
import emojify from 'mastodon/features/emoji/emoji';
import { emojiMuteTextParseCount, resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

jest.mock('mastodon/../images/elephant_ui_plane.svg', () => 'elephant.svg');
jest.mock('react-swipeable-views', () => ({ children }) => <div>{children}</div>);
jest.mock('mastodon/features/compose/containers/emoji_picker_dropdown_container', () => () => <button type='button'>pick</button>);
jest.mock('mastodon/components/animated_number', () => ({ value }) => <span>{value}</span>);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/components/icon_button', () => ({ title, onClick }) => <button type='button' aria-label={title} onClick={onClick} />);

jest.mock('react-intl', () => {
  const intl = {
    locale: 'en',
    formatDate: () => 'Jan 1',
    formatMessage: ({ defaultMessage }, values) => {
      let message = defaultMessage || '';

      if (values) {
        Object.keys(values).forEach(key => {
          message = message.replace(`{${key}}`, values[key] === undefined || values[key] === null ? '' : String(values[key]));
        });
      }

      return message;
    },
    now: () => Date.now(),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    FormattedDate: () => 'Jan 1',
  };
});

import Announcements from '../announcements';

const localImg = (id, shortcode = 'blob') => (
  `<img draggable="false" class="emojione custom-emoji" alt=":${shortcode}:" title="${shortcode}" src="https://cdn.example/${id}.svg" data-shortcode="${shortcode}" data-domain="" data-original="https://cdn.example/${id}.svg" data-static="https://cdn.example/${id}.png" data-emoji-id="${id}">`
);

const remoteImg = (domain, shortcode = 'blob') => (
  `<img draggable="false" class="emojione custom-emoji" alt=":${shortcode}:" title="${shortcode}" src="https://cdn.example/${domain}/${shortcode}.svg" data-shortcode="${shortcode}" data-domain="${domain}" data-original="https://cdn.example/${domain}/${shortcode}.svg" data-static="https://cdn.example/${domain}/${shortcode}.png">`
);

const rule = (emoji, replacement = '［絵文字］', effects = {}) => ({
  id: 'm1',
  revision: '2',
  emoji,
  replacement,
  effects: {
    replace_in_text: true,
    reject_reactions_to_own_posts: true,
    hide_reactions: true,
    hide_in_picker: true,
    ...effects,
  },
});

const makeStore = () => createStore((state = fromJS({ emojiMutes: { revision: null, rules: [] } }), action) => (
  state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action))
));

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes });
  });
};

class RouterStub extends React.Component {

  static propTypes = {
    children: PropTypes.node,
    router: PropTypes.object,
  };

  static childContextTypes = {
    router: PropTypes.object.isRequired,
  };

  getChildContext() {
    return { router: this.props.router };
  }

  render() {
    return this.props.children;
  }

}

const announcement = (contentHtml) => fromJS({
  id: 'an1',
  content: '<p>Hello :blob: #fedibird</p>',
  contentHtml,
  read: true,
  published_at: '2026-11-10T00:00:00.000Z',
  updated_at: '2026-11-10T00:00:00.000Z',
  all_day: true,
  mentions: [{ id: 'a1', url: 'https://example.test/@ada', acct: 'ada', group: false }],
  statuses: [{ id: 's1', url: 'https://example.test/statuses/s1' }],
  reactions: [{ name: '👍', count: 2, me: false }],
});

describe('announcement replace_in_text', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('replaces the mounted body, keeps links and reactions, and leaves the stored html', () => {
    const html = `<p>Hello ${localImg('10')} ${localImg('11', 'other')} <a href="https://example.test/@ada">@ada</a> <a href="https://example.test/tags/fedibird">#fedibird</a> <a href="https://example.test/outside">outside</a> <a href="https://example.test/statuses/s1">post</a></p>`;
    const record = announcement(html);
    const store = makeStore();
    const history = { push: jest.fn() };
    const { container } = render(
      <Provider store={store}>
        <RouterStub router={{ history }}>
          <Announcements
            announcements={fromJS([record])}
            emojiMap={fromJS({})}
            dismissAnnouncement={jest.fn()}
            addReaction={jest.fn()}
            removeReaction={jest.fn()}
          />
        </RouterStub>
      </Provider>,
    );
    const body = () => container.querySelector('.announcements__item__content');

    expect(body().querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(record.get('contentHtml')).toBe(html);
    expect(container.querySelector('.reactions-bar')).not.toBeNull();

    const parsed = emojiMuteTextParseCount();

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '<b>no</b>'),
    ]);

    expect(body().textContent).toContain('<b>no</b>');
    expect(body().querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(body().querySelector('[data-emoji-id="11"]')).not.toBeNull();
    expect(body().querySelector('b')).toBeNull();
    expect(body().innerHTML).not.toContain('cdn.example/10');
    expect(container.querySelector('.reactions-bar').textContent).toContain('2');
    expect(container.querySelector('.reactions-bar img, .reactions-bar button')).not.toBeNull();
    expect(record.get('content')).toBe('<p>Hello :blob: #fedibird</p>');
    expect(record.get('contentHtml')).toBe(html);
    expect(emojiMuteTextParseCount()).toBe(parsed + 1);

    fireEvent.click(body().querySelector('a[href="https://example.test/@ada"]'));
    fireEvent.click(body().querySelector('a[href="https://example.test/tags/fedibird"]'));
    fireEvent.click(body().querySelector('a[href="https://example.test/statuses/s1"]'));

    expect(history.push).toHaveBeenNthCalledWith(1, '/accounts/a1');
    expect(history.push).toHaveBeenNthCalledWith(2, '/timelines/tag/fedibird');
    expect(history.push).toHaveBeenNthCalledWith(3, '/statuses/s1');
    expect(body().querySelector('a[href="https://example.test/outside"]').getAttribute('target')).toBe('_blank');
    expect(body().querySelector('[data-emoji-id="11"]').getAttribute('src')).toContain('cdn.example/11.svg');

    fireEvent.mouseEnter(body());

    expect(body().querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(body().innerHTML).not.toContain('cdn.example/10');
    expect(body().querySelector('[data-emoji-id="11"]')).not.toBeNull();

    apply(store, [], '4');

    expect(body().querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(body().textContent).not.toContain('<b>no</b>');
  });

  it('keeps a reaction image when replace_in_text is off and records announcement identity', () => {
    const normalized = normalizeAnnouncement({
      id: 'an1',
      content: '<p>Hello :blob:</p>',
      emojis: [{
        id: '10',
        shortcode: 'blob',
        domain: null,
        url: 'https://cdn.example/10.svg',
        static_url: 'https://cdn.example/10.png',
      }],
      reactions: [],
    });

    expect(normalized.content).toBe('<p>Hello :blob:</p>');
    expect(normalized.contentHtml).toContain('data-emoji-id="10"');
    expect(normalized.contentHtml).toContain('data-domain=""');

    const record = announcement(normalized.contentHtml);
    const { container, store } = (() => {
      const nextStore = makeStore();
      const view = render(
        <Provider store={nextStore}>
          <Announcements
            announcements={fromJS([record])}
            emojiMap={fromJS({})}
            dismissAnnouncement={jest.fn()}
            addReaction={jest.fn()}
            removeReaction={jest.fn()}
          />
        </Provider>,
      );

      return { ...view, store: nextStore };
    })();

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]', { replace_in_text: false }),
    ]);

    expect(container.querySelector('.announcements__item__content [data-emoji-id="10"]')).not.toBeNull();
    expect(container.querySelector('.reactions-bar').textContent).toContain('2');
  });

  it('does not put a muted emoji url back into the link title', () => {
    const html = `<p><a class="custom-emoji-url-link" href="https://example.test/emoji/blob" data-shortcode="blob" title=":blob:">${localImg('10')}</a><a class="custom-emoji-url-link" href="https://a.test/emoji/blob" data-shortcode="blob" data-domain="a.test" title=":blob:">${remoteImg('a.test')}${remoteImg('b.test', 'other')}</a><a class="custom-emoji-url-link" href="https://b.test/emoji/kept" data-shortcode="kept" data-domain="b.test" title=":kept:">${remoteImg('b.test', 'kept')}</a> <a href="https://example.test/@ada">@ada</a> <a href="https://example.test/tags/fedibird">#fedibird</a> <a href="https://example.test/statuses/s1">post</a> <a href="https://example.test/outside">outside</a></p>`;
    const record = announcement(html);
    const store = makeStore();
    const history = { push: jest.fn() };
    const { container } = render(
      <Provider store={store}>
        <RouterStub router={{ history }}>
          <Announcements
            announcements={fromJS([record])}
            emojiMap={fromJS({})}
            dismissAnnouncement={jest.fn()}
            addReaction={jest.fn()}
            removeReaction={jest.fn()}
          />
        </RouterStub>
      </Provider>,
    );
    const body = () => container.querySelector('.announcements__item__content');
    const emojiLink = (href) => body().querySelector(`a[href="${href}"]`);

    expect(emojiLink('https://example.test/emoji/blob').getAttribute('title')).toBe('Link to :@blob:');
    expect(emojiLink('https://b.test/emoji/kept').getAttribute('title')).toBe('Link to :@kept: in @b.test');

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[remote]'),
    ]);

    const mutedLocal = emojiLink('https://example.test/emoji/blob');
    const mixed = emojiLink('https://a.test/emoji/blob');
    const kept = emojiLink('https://b.test/emoji/kept');

    expect(mutedLocal.getAttribute('href')).toBe('https://example.test/emoji/blob');
    expect(mutedLocal.getAttribute('title')).toBe('[local]');
    expect(mutedLocal.getAttribute('title')).not.toContain('example.test/emoji/blob');
    expect(mutedLocal.querySelector('img')).toBeNull();
    expect(mutedLocal.innerHTML).not.toContain('cdn.example/10');
    expect(mixed.getAttribute('href')).toBe('https://a.test/emoji/blob');
    expect(mixed.getAttribute('title')).not.toContain('a.test/emoji/blob');
    expect(mixed.getAttribute('title')).not.toContain(':blob:');
    expect(mixed.querySelector('[data-domain="a.test"]')).toBeNull();
    expect(mixed.querySelector('[data-domain="b.test"][data-shortcode="other"]')).not.toBeNull();
    expect(kept.getAttribute('title')).toBe('Link to :@kept: in @b.test');
    expect(kept.querySelector('[data-domain="b.test"]')).not.toBeNull();
    expect(emojiLink('https://example.test/outside').getAttribute('title')).toBe('https://example.test/outside');
    expect(container.querySelector('.reactions-bar').textContent).toContain('2');
    expect(record.get('contentHtml')).toBe(html);

    fireEvent.mouseEnter(body());

    expect(mutedLocal.querySelector('img')).toBeNull();
    expect(mutedLocal.getAttribute('title')).toBe('[local]');

    fireEvent.click(emojiLink('https://example.test/@ada'));
    fireEvent.click(emojiLink('https://example.test/tags/fedibird'));
    fireEvent.click(emojiLink('https://example.test/statuses/s1'));

    expect(history.push).toHaveBeenNthCalledWith(1, '/accounts/a1');
    expect(history.push).toHaveBeenNthCalledWith(2, '/timelines/tag/fedibird');
    expect(history.push).toHaveBeenNthCalledWith(3, '/statuses/s1');

    apply(store, [], '4');

    expect(emojiLink('https://example.test/emoji/blob').querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(emojiLink('https://example.test/emoji/blob').getAttribute('title')).toBe('Link to :@blob:');
    expect(emojiLink('https://a.test/emoji/blob').querySelector('[data-domain="a.test"]')).not.toBeNull();
    expect(emojiLink('https://a.test/emoji/blob').getAttribute('title')).toBe('Link to :@blob: in @a.test');
  });

  it('records each announcement emoji row domain', () => {
    const normalized = normalizeAnnouncement({
      id: 'an1',
      content: '<p>Hello :localblob: :remotea: :blob:</p>',
      emojis: [
        { id: '10', shortcode: 'localblob', domain: null, url: 'https://cdn.example/10.svg', static_url: 'https://cdn.example/10.png' },
        { id: '20', shortcode: 'remotea', domain: 'a.test', url: 'https://cdn.example/a.svg', static_url: 'https://cdn.example/a.png' },
        { id: '19', shortcode: 'blob', domain: 'a.test', url: 'https://cdn.example/a-blob.svg', static_url: 'https://cdn.example/a-blob.png' },
        { id: '22', shortcode: 'blob', domain: 'b.test', url: 'https://cdn.example/b-blob.svg', static_url: 'https://cdn.example/b-blob.png' },
      ],
    });
    const authorHtml = emojify('<p>:blob:</p>', {
      ':blob:': { id: '7', shortcode: 'blob', domain: 'row.test', url: 'https://cdn.example/7.svg', static_url: 'https://cdn.example/7.png' },
    }, 'author.test');

    expect(normalized.content).toBe('<p>Hello :localblob: :remotea: :blob:</p>');
    expect(normalized.contentHtml).toContain('data-emoji-id="10"');
    expect(normalized.contentHtml).toContain('data-domain="a.test"');
    expect(normalized.contentHtml).toContain('data-domain="b.test"');
    expect(normalized.contentHtml).not.toContain('data-emoji-id="22"');
    expect(authorHtml).toContain('data-domain="author.test"');
    expect(authorHtml).not.toContain('data-domain="row.test"');
  });
});
