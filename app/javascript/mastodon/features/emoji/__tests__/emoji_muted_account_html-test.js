import React from 'react';
import PropTypes from 'prop-types';
import { act, fireEvent, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import emojiMutes from 'mastodon/reducers/emoji_mutes';
import { emojiMuteTextParseCount, resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';

jest.mock('react-intl', () => {
  const ReactIntl = require('react');

  const formatMessage = ({ defaultMessage }, values = {}) => {
    if (!defaultMessage) {
      return '';
    }

    return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => {
      const value = values[key];

      if (ReactIntl.isValidElement(value) || value === undefined || value === null) {
        return '';
      }

      return String(value);
    });
  };

  const intl = {
    locale: 'en',
    formatMessage,
    formatDate: () => 'Jan 1',
    formatNumber: value => String(value),
    now: () => Date.now(),
  };

  const FormattedMessage = ({ defaultMessage, values }) => {
    if (!values) {
      return defaultMessage;
    }

    const parts = [];
    const pattern = /\{(\w+)\}/g;
    let last = 0;
    let match = pattern.exec(defaultMessage || '');
    let element = false;

    while (match) {
      parts.push((defaultMessage || '').slice(last, match.index));
      const value = values[match[1]];

      if (ReactIntl.isValidElement(value)) {
        element = true;
      }

      parts.push(value === undefined || value === null ? '' : value);
      last = match.index + match[0].length;
      match = pattern.exec(defaultMessage || '');
    }

    parts.push((defaultMessage || '').slice(last));

    if (!element) {
      return parts.join('');
    }

    return ReactIntl.createElement(ReactIntl.Fragment, null, ...parts);
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage,
    FormattedDate: () => 'Jan 1',
  };
});

jest.mock('react-hotkeys', () => {
  const ReactHotkeys = require('react');
  const PropTypesHotkeys = require('prop-types');
  const HotKeys = ({ children }) => ReactHotkeys.createElement('div', null, children);

  HotKeys.propTypes = { children: PropTypesHotkeys.node };

  return { HotKeys };
});

jest.mock('react-router-dom', () => {
  const ReactRouter = require('react');
  const PropTypesRouter = require('prop-types');
  const NavLink = ({ children }) => ReactRouter.createElement('a', { href: '/' }, children);

  NavLink.propTypes = { children: PropTypesRouter.node };

  return { NavLink };
});

jest.mock('mastodon/components/avatar', () => () => <span data-testid='avatar' />);
jest.mock('mastodon/components/short_number', () => () => <span>1</span>);
jest.mock('mastodon/containers/dropdown_menu_container', () => () => null);
jest.mock('mastodon/containers/status_container', () => () => null);
jest.mock('mastodon/containers/account_container', () => () => null);
jest.mock('mastodon/features/notifications/containers/follow_request_container', () => () => null);
jest.mock('mastodon/features/account/containers/account_note_container', () => () => null);
jest.mock('mastodon/features/account/components/notification_settings', () => () => null);

import DisplayName from 'mastodon/components/display_name';
import Content from 'mastodon/components/content';
import Account from 'mastodon/components/account';
import Header from 'mastodon/features/account/components/header';
import Notification from 'mastodon/features/notifications/components/notification';
import { EmojiMutedPlain, bindCustomEmojiHover, unbindCustomEmojiHover } from 'mastodon/components/emoji_muted_html';

const THUMB = '👍';
const FAMILY = '👨‍👩‍👧‍👧';

const unicodeImg = (native, src) => (
  `<img draggable="false" class="emojione" alt="${native}" title="${native}" src="${src}" data-original="${src}" data-static="${src}">`
);

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

const firstSentence = value => value.split('.')[0];

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes });
  });
};

const makeStore = (account) => createStore((state, action) => {
  const current = state || fromJS({
    emojiMutes: { revision: null, rules: [] },
    accounts: account ? { a1: account } : {},
    accounts_counters: {},
    relationships: {},
  });

  return current.set('emojiMutes', emojiMutes(current.get('emojiMutes'), action));
});

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

describe('account replace_in_text presentation', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('replaces a display name, keeps another local id, and updates a mounted row', () => {
    const html = `Ada ${unicodeImg(THUMB, '/emoji/thumb.svg')} ${localImg('10')} ${localImg('11')} ${remoteImg('a.test')} ${remoteImg('b.test')} ${unicodeImg(FAMILY, '/emoji/family.svg')}`;
    const account = fromJS({
      id: 'a1',
      username: 'ada',
      acct: 'ada@example.test',
      url: 'https://example.test/@ada',
      display_name_html: html,
    });
    const store = makeStore();
    const { container } = render(
      <Provider store={store}>
        <DisplayName account={account} />
      </Provider>,
    );

    expect(container.querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(account.get('display_name_html')).toBe(html);

    const parsed = emojiMuteTextParseCount();

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '<img src=x onerror=alert(1)>'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[remote]'),
    ]);

    expect(container.textContent).toContain('[local]');
    expect(container.textContent).toContain('[remote]');
    expect(container.querySelector(`img[alt="${FAMILY}"]`)).not.toBeNull();
    expect(container.querySelector('[data-emoji-id="11"]')).not.toBeNull();
    expect(container.querySelector('[data-domain="b.test"]')).not.toBeNull();
    expect(container.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(container.querySelector('[data-domain="a.test"]')).toBeNull();
    expect(container.querySelector('img[src*="thumb"]')).toBeNull();
    expect(container.querySelectorAll('img').length).toBe(3);
    expect(container.querySelector('img[onerror]')).toBeNull();
    expect(container.textContent).toContain('<img src=x onerror=alert(1)>');
    expect(account.get('display_name_html')).toBe(html);
    expect(emojiMuteTextParseCount()).toBe(parsed + 1);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '<img src=x onerror=alert(1)>'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[remote]'),
    ], '3');

    expect(emojiMuteTextParseCount()).toBe(parsed + 1);

    fireEvent.mouseEnter(container.querySelector('.display-name'));

    expect(container.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(container.querySelector('[data-original*="cdn.example/10"]')).toBeNull();
    expect(container.querySelector('[data-emoji-id="11"]').getAttribute('src')).toContain('cdn.example/11.svg');

    apply(store, [], '4');

    expect(container.querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(container.textContent).not.toContain('[local]');
  });

  it('replaces only the muted name when several accounts are shown', () => {
    const store = makeStore();
    const muted = fromJS({ id: '1', acct: 'a@example.test', display_name_html: `A ${localImg('10')}` });
    const kept = fromJS({ id: '2', acct: 'b@example.test', display_name_html: `B ${localImg('11', 'other')}` });
    const { container } = render(
      <Provider store={store}>
        <DisplayName account={muted} others={fromJS([muted, kept, fromJS({ id: '3', acct: 'c', display_name_html: 'C' })])} />
      </Provider>,
    );

    apply(store, [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[a]')]);

    expect(container.textContent).toContain('A [a]');
    expect(container.textContent).toContain('B ');
    expect(container.querySelector('[data-emoji-id="11"]')).not.toBeNull();
    expect(container.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(container.textContent).toContain('+1');
  });

  it('keeps a profile link clickable once and leaves replace_in_text false untouched', () => {
    const html = `<p>Hi ${localImg('10')} <a href="https://example.test/tags/bird">#bird</a></p>`;
    const push = jest.fn();
    const store = makeStore();
    const { container } = render(
      <Provider store={store}>
        <RouterStub router={{ history: { push } }}>
          <Content contentHtml={{ __html: html }} />
        </RouterStub>
      </Provider>,
    );
    const link = container.querySelector('a');

    fireEvent.click(link);
    apply(store, [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[bio]')]);

    expect(container.textContent).toContain('[bio]');
    expect(container.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(container.querySelector('[data-original]')).toBeNull();
    expect(container.querySelector('a').getAttribute('href')).toBe('https://example.test/tags/bird');

    fireEvent.click(container.querySelector('a'));
    apply(store, [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '99', shortcode: 'blob' }, '[no]')], '5');
    fireEvent.click(container.querySelector('a'));

    expect(push).toHaveBeenCalledTimes(3);
    expect(push).toHaveBeenCalledWith('/timelines/tag/bird');
    expect(container.textContent).not.toContain('[bio]');
    expect(container.querySelector('[data-emoji-id="10"]')).not.toBeNull();

    apply(store, [rule(
      { kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' },
      '[off]',
      { replace_in_text: false },
    )], '6');

    expect(container.querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(container.textContent).not.toContain('[off]');

    apply(store, [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '')], '7');

    expect(container.textContent).toContain('Hi');
    expect(container.querySelector('img')).toBeNull();
    expect(container.querySelector('a')).not.toBeNull();
    fireEvent.mouseEnter(container.querySelector('span'));
    expect(container.querySelector('img')).toBeNull();
  });

  it('updates the account header name, bio, follow message, and field labels', () => {
    const push = jest.fn();
    const nameHtml = `Ada ${localImg('10')} ${unicodeImg(FAMILY, '/emoji/family.svg')}`;
    const noteHtml = `<p>Bio ${localImg('10')} <a href="https://example.test/tags/bird">#bird</a></p>`;
    const followHtml = `<p>Welcome ${remoteImg('a.test')}</p>`;
    const fieldName = `Mood ${THUMB}`;
    const fieldValue = `See ${THUMB} :blob:`;
    const account = fromJS({
      id: 'a1',
      username: 'ada',
      acct: 'ada',
      url: 'https://example.test/@ada',
      display_name: 'Ada',
      display_name_html: nameHtml,
      note: '<p>Bio</p>',
      note_emojified: noteHtml,
      followed_message: 'Welcome',
      followed_message_emojified: followHtml,
      avatar: 'https://example.test/a.png',
      header: 'https://example.test/h.png',
      header_static: 'https://example.test/h.png',
      statuses_count: 1,
      following_count: 2,
      followers_count: 3,
      created_at: '2020-01-01T00:00:00.000Z',
      fields: [{
        name: fieldName,
        name_emojified: `Mood ${unicodeImg(THUMB, '/emoji/thumb.svg')}`,
        value: '<p>See</p>',
        value_plain: fieldValue,
        value_emojified: `<p>See ${unicodeImg(THUMB, '/emoji/thumb.svg')} ${localImg('10')}</p>`,
        verified_at: null,
      }],
      relationship: {
        following: true,
        delivery_following: true,
        followed_by: false,
        blocking: false,
        muting: false,
        requested: false,
        blocked_by: false,
        showing_reblogs: true,
        endorsed: false,
      },
    });
    const store = makeStore();
    const { container } = render(
      <Provider store={store}>
        <RouterStub router={{ history: { push } }}>
          <Header
            account={account}
            domain='example.test'
            hideProfile={false}
            identity_proofs={fromJS([])}
            onFollow={jest.fn()}
            onSubscribe={jest.fn()}
            onAddToList={jest.fn()}
            onBlock={jest.fn()}
            onMention={jest.fn()}
            onDirect={jest.fn()}
            onConversations={jest.fn()}
            onReblogToggle={jest.fn()}
            onReport={jest.fn()}
            onMute={jest.fn()}
            onBlockDomain={jest.fn()}
            onUnblockDomain={jest.fn()}
            onEndorseToggle={jest.fn()}
            onEditAccountNote={jest.fn()}
          />
        </RouterStub>
      </Provider>,
    );
    const header = container.querySelector('.account__header');

    expect(header.textContent).toContain('Ada');
    expect(header.querySelectorAll('[data-emoji-id="10"]').length).toBeGreaterThan(1);
    expect(header.querySelector('dt').getAttribute('title')).toBe(fieldName);
    expect(header.querySelector('dd').getAttribute('title')).toBe(fieldValue);

    fireEvent.click(header.querySelector('h1 .custom-emoji'));
    expect(push).toHaveBeenCalledTimes(1);
    expect(push).toHaveBeenCalledWith('/emoji_detail/blob');

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[ada]'),
      rule({ kind: 'unicode', native: THUMB }, '[mood]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[hi]'),
    ]);

    expect(header.querySelector('h1').textContent).toContain('Ada [ada]');
    expect(header.querySelector('h1 img[alt="' + FAMILY + '"]')).not.toBeNull();
    expect(header.querySelector('.account__header__content').textContent).toContain('Bio [ada]');
    expect(header.querySelector('.account__header__followed_message').textContent).toContain('Welcome [hi]');
    expect(header.querySelector('dt').textContent).toContain('Mood [mood]');
    expect(header.querySelector('dd').textContent).toContain('See [mood] [ada]');
    expect(header.querySelector('dt').getAttribute('title')).toBe('Mood [mood]');
    expect(header.querySelector('dd').getAttribute('title')).toBe('See [mood] [ada]');
    expect(header.querySelector('dt').getAttribute('title')).not.toContain(THUMB);
    expect(header.querySelector('dd').getAttribute('title')).not.toContain(':blob:');
    expect(header.querySelector('a[href="https://example.test/tags/bird"]')).not.toBeNull();
    expect(header.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(header.querySelector('[data-domain="a.test"]')).toBeNull();
    expect(header.querySelector('img[src*="/emoji/family.svg"]')).not.toBeNull();
    expect(account.get('display_name_html')).toBe(nameHtml);
    expect(account.get('note_emojified')).toBe(noteHtml);
    expect(account.getIn(['fields', 0, 'name'])).toBe(fieldName);

    fireEvent.mouseEnter(header);
    fireEvent.click(header.querySelector('h1'));

    expect(header.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(push).toHaveBeenCalledTimes(1);

    apply(store, [], '8');
    fireEvent.click(header.querySelector('h1 .custom-emoji'));

    expect(push).toHaveBeenCalledTimes(2);
    expect(header.querySelector('dt').getAttribute('title')).toBe(fieldName);
  });

  it('updates a list row and a notification name without rewriting the account', () => {
    const html = `Ada ${localImg('10')}`;
    const plainAccount = {
      id: 'a1',
      username: 'ada',
      acct: 'ada',
      url: 'https://example.test/@ada',
      display_name: 'Ada',
      display_name_html: html,
      avatar: '',
      note: '',
      followed_message: 'Welcome',
      followed_message_emojified: `<p>${remoteImg('a.test')}</p>`,
    };
    const account = fromJS(plainAccount);
    const store = makeStore(plainAccount);
    const { container } = render(
      <Provider store={store}>
        <Account
          account={account}
          onFollow={jest.fn()}
          onSubscribe={jest.fn()}
          onAddToList={jest.fn()}
          onBlock={jest.fn()}
          onMute={jest.fn()}
          onMuteNotifications={jest.fn()}
        />
        <Notification
          notification={fromJS({
            id: 'n1',
            type: 'followed',
            created_at: '2026-01-01T00:00:00.000Z',
            account,
            target_account: account,
          })}
          onMoveUp={jest.fn()}
          onMoveDown={jest.fn()}
          onMention={jest.fn()}
          onFavourite={jest.fn()}
          onReblog={jest.fn()}
          onToggleHidden={jest.fn()}
        />
      </Provider>,
    );

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[row]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[msg]'),
    ]);

    expect(container.querySelector('.account').textContent).toContain('Ada [row]');
    expect(container.querySelector('.notification__display-name').textContent).toContain('[row]');
    expect(container.querySelector('.notification__followed_message').textContent).toContain('[msg]');
    expect(container.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(container.querySelector('[data-domain="a.test"]')).toBeNull();
    expect(account.get('display_name_html')).toBe(html);
    expect(store.getState().getIn(['accounts', 'a1', 'display_name_html'])).toBe(html);
  });

  it('shortens a recommendation note only after a mute changes it', () => {
    const plain = `Hello ${THUMB}. Second sentence.`;
    const html = `<p>Hello ${unicodeImg(THUMB, '/emoji/thumb.svg')}. Second sentence.</p>`;
    const store = makeStore();
    const { container } = render(
      <Provider store={store}>
        <EmojiMutedPlain className='account__note' plain={plain} html={html} format={firstSentence} />
      </Provider>,
    );

    expect(container.querySelector('.account__note').textContent).toBe(`Hello ${THUMB}`);

    apply(store, [rule({ kind: 'unicode', native: THUMB }, '[hi]')]);

    expect(container.querySelector('.account__note').textContent).toBe('Hello [hi]');
    expect(container.querySelector('.account__note').textContent).not.toContain(THUMB);
    expect(container.querySelector('img')).toBeNull();
  });

  it('keeps hover on emoji that appear after the note node was bound', () => {
    const node = document.createElement('div');
    node.innerHTML = localImg('10');
    document.body.appendChild(node);
    bindCustomEmojiHover(
      node,
      emoji => {
        emoji.src = emoji.getAttribute('data-original');
      },
      emoji => {
        emoji.src = emoji.getAttribute('data-static');
      },
    );

    fireEvent.mouseOver(node.querySelector('img'));
    expect(node.querySelector('img').getAttribute('src')).toContain('cdn.example/10.svg');

    node.innerHTML = '［絵文字］';
    fireEvent.mouseOver(node);
    expect(node.querySelector('img')).toBeNull();
    expect(node.textContent).toBe('［絵文字］');

    node.innerHTML = localImg('11');
    fireEvent.mouseOver(node.querySelector('img'));
    expect(node.querySelector('img').getAttribute('src')).toContain('cdn.example/11.svg');

    unbindCustomEmojiHover(node);
    node.remove();
  });

  it('does not republish a muted emoji shortcode on the profile link title', () => {
    const html = `<p>Hi <a class="custom-emoji-url-link" href="https://remote.example/emoji/blob" data-shortcode="blob" data-domain="remote.example" title=":blob:" aria-label="blob at remote.example">${remoteImg('remote.example', 'blob')}</a> <a href="https://example.test/tags/bird">#bird</a> <a class="mention" href="https://example.test/@ada" data-account-id="9" data-account-acct="ada">@ada</a></p>`;
    const push = jest.fn();
    const store = makeStore();
    const { container } = render(
      <Provider store={store}>
        <RouterStub router={{ history: { push } }}>
          <Content contentHtml={{ __html: html }} />
        </RouterStub>
      </Provider>,
    );

    apply(store, [rule({ kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' }, '[safe]')]);

    const emojiLink = container.querySelector('a.custom-emoji-url-link');

    expect(container.querySelector('img')).toBeNull();
    expect(emojiLink.getAttribute('title')).toBe('[safe]');
    expect(emojiLink.hasAttribute('aria-label')).toBe(false);
    container.querySelectorAll('a').forEach(anchor => {
      expect(anchor.getAttribute('title') || '').not.toContain('blob');
      expect(anchor.getAttribute('title') || '').not.toContain('remote.example');
      expect(anchor.getAttribute('aria-label') || '').not.toContain('blob');
      expect(anchor.getAttribute('aria-label') || '').not.toContain('remote.example');
    });
    expect(container.querySelector('a.mention').getAttribute('title')).toBe('Link to @ada');
    expect(container.querySelector('a[href="https://example.test/tags/bird"]')).not.toBeNull();

    fireEvent.click(container.querySelector('a[href="https://example.test/tags/bird"]'));
    fireEvent.click(container.querySelector('a.mention'));

    apply(store, [], '9');

    expect(container.querySelector('a.custom-emoji-url-link img')).not.toBeNull();
    expect(container.querySelector('a.custom-emoji-url-link').getAttribute('title')).toBe('Link to :@blob: in @remote.example');
    expect(container.querySelector('a.mention').getAttribute('title')).toBe('Link to @ada');

    fireEvent.click(container.querySelector('a[href="https://example.test/tags/bird"]'));
    fireEvent.click(container.querySelector('a.mention'));

    expect(push.mock.calls.filter(call => call[0] === '/timelines/tag/bird')).toHaveLength(2);
    expect(push.mock.calls.filter(call => call[0] === '/accounts/9')).toHaveLength(2);
  });

  it('hides a muted emoji inside a link that still shows another emoji', () => {
    const html = `<p><a class="custom-emoji-url-link" href="https://remote.example/emoji/blob" data-shortcode="blob" data-domain="remote.example" title=":blob:" aria-label="blob">${remoteImg('remote.example', 'blob')}${remoteImg('other.example', 'other')}</a><a class="custom-emoji-url-link" href="https://example.test/emoji/cat" data-shortcode="cat" title="category" aria-label="See the category">${localImg('4', 'cat')}</a></p>`;
    const store = makeStore();
    const { container } = render(
      <Provider store={store}>
        <Content contentHtml={{ __html: html }} />
      </Provider>,
    );

    apply(store, [
      rule({ kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' }, '[safe]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '4', shortcode: 'cat' }, '[cat]'),
    ]);

    const blobLink = container.querySelector('a[data-domain="remote.example"]');
    const catLink = container.querySelector('a[data-shortcode="cat"]');

    expect(blobLink.querySelector('[data-shortcode="blob"]')).toBeNull();
    expect(blobLink.querySelector('[data-shortcode="other"]').getAttribute('src')).toContain('other.example');
    expect(blobLink.getAttribute('title')).toBe('[safe]');
    expect(blobLink.hasAttribute('aria-label')).toBe(false);
    expect(blobLink.getAttribute('href')).toBe('https://remote.example/emoji/blob');
    expect(catLink.querySelector('img')).toBeNull();
    expect(catLink.getAttribute('title')).toBe('category');
    expect(catLink.getAttribute('aria-label')).toBe('See the category');

    apply(store, [], '11');

    expect(container.querySelector('a[data-domain="remote.example"] [data-shortcode="blob"]')).not.toBeNull();
    expect(container.querySelector('a[data-domain="remote.example"] [data-shortcode="other"]')).not.toBeNull();
    expect(container.querySelector('a[data-domain="remote.example"]').getAttribute('title')).toBe('Link to :@blob: in @remote.example');
    expect(container.querySelector('a[data-shortcode="cat"] img')).not.toBeNull();
    expect(container.querySelector('a[data-shortcode="cat"]').getAttribute('title')).toBe('Link to :@cat:');
  });

  it('keeps emoji and hashtag clicks after onClick is toggled', () => {
    const html = '<p><img draggable="false" class="emojione custom-emoji" alt=":blob:" title="blob" src="https://cdn.example/plain.svg" data-shortcode="blob" data-domain="" data-original="https://cdn.example/plain.svg" data-static="https://cdn.example/plain.png"><a href="https://example.test/tags/bird">#bird</a></p>';
    const push = jest.fn();
    const onClick = jest.fn();
    const store = makeStore();
    const ui = clickHandler => (
      <Provider store={store}>
        <RouterStub router={{ history: { push } }}>
          <Content contentHtml={{ __html: html }} onClick={clickHandler} />
        </RouterStub>
      </Provider>
    );
    const view = render(ui(undefined));
    const clickEmoji = () => fireEvent.click(view.container.querySelector('.custom-emoji'));
    const clickTag = () => fireEvent.click(view.container.querySelector('a'));

    clickEmoji();
    clickTag();
    view.rerender(ui(onClick));
    clickEmoji();
    clickTag();
    view.rerender(ui(undefined));
    clickEmoji();
    clickTag();

    expect(push.mock.calls.filter(call => call[0] === '/emoji_detail/blob')).toHaveLength(3);
    expect(push.mock.calls.filter(call => call[0] === '/timelines/tag/bird')).toHaveLength(3);

    const node = view.container.querySelector('span');
    const remove = jest.spyOn(node, 'removeEventListener');
    view.unmount();
    expect(remove).toHaveBeenCalledWith('click', expect.any(Function), true);
  });
});
