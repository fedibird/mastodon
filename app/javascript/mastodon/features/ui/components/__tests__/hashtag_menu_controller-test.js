/* eslint-disable react/prop-types */

import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { fromJS } from 'immutable';
import PropTypes from 'prop-types';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

const mockApiPost = jest.fn();

jest.mock('mastodon/api', () => () => ({
  post: (...args) => mockApiPost(...args),
}));

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
  const Overlay = ({ show, children, target }) => {
    if (!show) {
      return null;
    }

    Overlay.lastTarget = typeof target === 'function' ? target() : target;

    return children({ props: { style: {} }, arrowProps: {}, placement: 'bottom' });
  };

  return Overlay;
});

jest.mock('react-intl', () => {
  const interpolate = (defaultMessage, values) => {
    if (!values) {
      return defaultMessage;
    }

    return defaultMessage.split(/\{(\w+)\}/g).map((part, index) => (
      index % 2 === 1 ? values[part] : part
    )).join('');
  };
  const intl = {
    locale: 'ja-JP',
    formatMessage: ({ defaultMessage }, values) => interpolate(defaultMessage, values),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => interpolate(defaultMessage, values),
  };
});

jest.mock('mastodon/containers/poll_container', () => () => <div className='status__poll-stub' />);
jest.mock('mastodon/components/permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('mastodon/components/icon', () => () => null);

import Overlay from 'react-overlays/Overlay';
import { fetchFavouriteTagSuccess } from 'mastodon/actions/favourite_tags';
import { EMOJI_MUTES_APPLY, EMOJI_MUTES_DISABLE, EMOJI_MUTES_ENABLE, EMOJI_MUTES_FAIL, EMOJI_MUTES_IGNORE, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import emojify from 'mastodon/features/emoji/emoji';
import { hashtagMenuStoredName } from 'mastodon/features/emoji/hashtag_menu_names';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import favouriteTagsReducer from 'mastodon/reducers/favourite_tags';
import emojiMutesReducer from 'mastodon/reducers/emoji_mutes';
import StatusContent from 'mastodon/components/status_content';
import HashtagMenuController from '../hashtag_menu_controller';

let history;

class RouterProvider extends React.Component {

  static childContextTypes = {
    router: PropTypes.object,
  };

  getChildContext () {
    return { router: { history } };
  }

  render () {
    return this.props.children;
  }

}

function anchor(name) {
  return `<a href="https://example.com/tags/${encodeURIComponent(name)}" class="mention hashtag" rel="tag">#<span>${name}</span></a>`;
}

const contentHtml = `<p>See ${anchor('test')} today<br><br>${anchor('mastodon')} ${anchor('Test')} ${anchor('fedibird')}</p>`;

const translation = {
  contentHtml: `<p>こんにちは ${anchor('different')}</p>`,
  spoilerHtml: '',
  language: 'ja',
  detected_source_language: 'en',
  requested_source_language: 'en',
  requested_target_language: 'ja',
  provider: 'DeepL',
};

function reducer(state, action) {
  const emojiType = action && typeof action.type === 'string' && action.type.indexOf('EMOJI_MUTES_') === 0;
  let next = state;

  if (emojiType || next.has('emojiMutes')) {
    next = next.set('emojiMutes', emojiMutesReducer(next.get('emojiMutes'), action));
  }

  next = next.set('favourite_tags', favouriteTagsReducer(next.get('favourite_tags'), action));

  if (action.type === 'MODAL_OPEN') {
    return next.set('modal', fromJS({ modalType: action.modalType, hashtag: action.modalProps.hashtag }));
  }

  if (action.type !== 'ALERT_SHOW') {
    return next;
  }

  return next.update('alerts', alerts => alerts.push(fromJS({ message: action.message })));
}

function initialState() {
  return fromJS({
    server: {
      translationLanguages: {
        items: {
          en: ['ja'],
          und: ['ja'],
        },
      },
    },
    accounts: {
      a1: { id: 'a1', display_name: 'Alice', username: 'alice', acct: 'alice', url: 'https://example.com/@alice' },
    },
    statuses: {
      s1: {
        id: 's1',
        contentHtml,
        account: 'a1',
      },
    },
    favourite_tags: {},
    alerts: [],
  });
}

function buildStatus(overrides = {}) {
  return fromJS({
    id: 's1',
    contentHtml,
    spoilerHtml: '',
    spoiler_text: '',
    search_index: 'See test today',
    language: 'en',
    visibility: 'public',
    mentions: [],
    account: { id: 'a1', display_name: 'Alice', username: 'alice', acct: 'alice' },
    ...overrides,
  });
}

function renderMenu({ status, signedIn, onClick = jest.fn(), account, accounts, tags, contentHtml: html, emojiMutes } = {}) {
  let state = initialState();

  if (account) {
    state = state.setIn(['accounts', 'a1'], fromJS(account));
  }

  if (accounts) {
    Object.keys(accounts).forEach(id => {
      state = state.setIn(['accounts', id], fromJS(accounts[id]));
    });
  }

  if (html) {
    state = state.setIn(['statuses', 's1', 'contentHtml'], html);
  }

  if (tags) {
    state = state.setIn(['statuses', 's1', 'tags'], fromJS(tags));
  }

  if (emojiMutes) {
    state = state.set('emojiMutes', fromJS(emojiMutes));
  }

  const statusProp = status || buildStatus({
    ...(html ? { contentHtml: html } : {}),
    ...(tags ? { tags } : {}),
  });
  const store = createStore(reducer, state, applyMiddleware(thunk));
  const view = render(
    <Provider store={store}>
      <RouterProvider>
        <StatusContent status={statusProp} onTranslate={jest.fn()} onClick={onClick} />
        <HashtagMenuController signedIn={signedIn} />
      </RouterProvider>
    </Provider>,
  );

  return { ...view, store, onClick };
}

function click(node, init = {}) {
  const event = new MouseEvent('click', { bubbles: true, cancelable: true, button: 0, ...init });

  act(() => {
    node.dispatchEvent(event);
  });

  return event;
}

describe('HashtagMenuController', () => {
  beforeEach(() => {
    history = { push: jest.fn() };
    mockApiPost.mockReset();
    mockApiPost.mockImplementation((_url, body) => Promise.resolve({
      data: { id: 'ft1', name: body.name, updated_at: '2020-01-02T00:00:00.000Z' },
    }));
    window.open = jest.fn();
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText: jest.fn(() => Promise.resolve()) },
    });
  });

  it.each([' ', '<br>'])('opens the menu and copies tags kept inline with separator %s', separator => {
    const { container } = renderMenu({
      contentHtml: `<p>Hello${separator}${anchor('test')} ${anchor('fedibird')}</p>`,
    });
    const links = container.querySelectorAll('.status__content__text a.mention.hashtag');

    expect(links).toHaveLength(2);
    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();
    click(links[1]);
    expect(screen.getByRole('button', { name: 'View posts with #fedibird' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtag' }));
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith('#fedibird');
    click(links[0]);
    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtags' }));
    expect(navigator.clipboard.writeText).toHaveBeenLastCalledWith('#test #fedibird');
  });

  it('marks body hashtags and trailing badges, and opens the menu on either', () => {
    const { container } = renderMenu();
    const inline = container.querySelector('.status__content__text a.mention.hashtag');
    const badge = container.querySelector('.status__content__hashtag-badge');

    expect(inline.textContent).toBe('#test');
    expect(inline).toHaveAttribute('data-menu-hashtag', 'test');
    expect(inline).toHaveAttribute('data-account-id', 'a1');
    expect(inline).toHaveAttribute('data-status-id', 's1');
    expect(badge).toHaveAttribute('data-menu-hashtag', 'mastodon');
    expect(badge).toHaveAttribute('data-account-id', 'a1');
    expect(badge).toHaveAttribute('data-status-id', 's1');

    click(inline.querySelector('span'));

    expect(screen.getByRole('button', { name: 'View posts with #test' })).toHaveAttribute('href', `${window.location.origin}/tags/test`);
    expect(Overlay.lastTarget).toBe(inline);

    click(badge);

    expect(screen.getByRole('button', { name: 'View posts with #mastodon' })).toHaveAttribute('href', `${window.location.origin}/tags/mastodon`);
    expect(screen.getByRole('button', { name: 'View alice\'s posts with #mastodon' })).toHaveAttribute('href', `${window.location.origin}/@alice/tagged/mastodon`);
    expect(Overlay.lastTarget).toBe(badge);
  });

  it('opens the two Fedibird timelines from the menu and leaves modified clicks on the link', () => {
    const { container } = renderMenu();
    const inline = container.querySelector('.status__content__text a.mention.hashtag');
    const badge = container.querySelector('a.status__content__hashtag-badge');

    const ctrl = click(inline, { ctrlKey: true });
    const command = click(badge, { metaKey: true });
    const middle = click(badge, { button: 1 });
    const right = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, button: 2 });
    badge.dispatchEvent(right);

    expect(ctrl.defaultPrevented).toBe(false);
    expect(command.defaultPrevented).toBe(false);
    expect(middle.defaultPrevented).toBe(false);
    expect(right.defaultPrevented).toBe(false);
    expect(history.push).not.toHaveBeenCalled();
    expect(screen.queryByRole('button', { name: 'View posts with #test' })).toBeNull();

    const opened = click(badge);
    expect(opened.defaultPrevented).toBe(true);

    fireEvent.click(screen.getByRole('button', { name: 'View posts with #mastodon' }));
    expect(history.push).toHaveBeenCalledWith('/timelines/tag/mastodon');
    expect(history.push).not.toHaveBeenCalledWith(expect.stringContaining('/tagged/'));

    click(inline);
    fireEvent.click(screen.getByRole('button', { name: 'View alice\'s posts with #test' }));
    expect(history.push).toHaveBeenCalledWith('/accounts/a1/posts/test');
    expect(history.push.mock.calls.map(call => call[0]).join(' ')).not.toContain('/@');
  });

  it('points hrefs at the local public pages for local posts while routing in-app with WebUI paths, including encoded tags', () => {
    const tag = 'ハッシュタグ_テスト';
    const encoded = encodeURIComponent(tag);
    const { container } = renderMenu({
      contentHtml: `<p>${anchor(tag)}</p>`,
    });

    click(container.querySelector('.status__content__text a.mention.hashtag'));

    const browse = screen.getByRole('button', { name: `View posts with #${tag}` });
    const browseAccount = screen.getByRole('button', { name: `View alice's posts with #${tag}` });

    expect(browse).toHaveAttribute('href', `${window.location.origin}/tags/${encoded}`);
    expect(browseAccount).toHaveAttribute('href', `${window.location.origin}/@alice/tagged/${encoded}`);

    fireEvent.click(browse);
    expect(history.push).toHaveBeenLastCalledWith(`/timelines/tag/${encoded}`);

    click(container.querySelector('.status__content__text a.mention.hashtag'));
    fireEvent.click(screen.getByRole('button', { name: `View alice's posts with #${tag}` }));
    expect(history.push).toHaveBeenLastCalledWith(`/accounts/a1/posts/${encoded}`);
  });

  describe('hrefs of remote posts', () => {
    const remoteAccount = { id: 'a1', display_name: 'Bob', username: 'bob', acct: 'bob@remote.example', url: 'https://remote.example/@bob' };

    function renderRemote({ html, tags, account = remoteAccount } = {}) {
      return renderMenu({
        account,
        contentHtml: html,
        tags,
        status: buildStatus({ account, contentHtml: html, ...(tags ? { tags } : {}) }),
      });
    }

    function hrefAttr(name) {
      return screen.getByRole('button', { name }).getAttribute('href');
    }

    it('uses the remote tag link of an inline anchor and never the WebUI path', () => {
      const tag = 'タグ';
      const encoded = encodeURIComponent(tag);
      const html = `<p><a href="https://remote.example/tags/${encoded}" class="mention hashtag" rel="tag">#<span>${tag}</span></a></p>`;
      const { container } = renderRemote({ html });

      click(container.querySelector('.status__content__text a.mention.hashtag'));

      expect(hrefAttr(`View posts with #${tag}`)).toBe(`https://remote.example/tags/${encoded}`);
      expect(hrefAttr(`View bob's posts with #${tag}`)).toBeNull();

      fireEvent.click(screen.getByRole('button', { name: `View posts with #${tag}` }));
      expect(history.push).toHaveBeenLastCalledWith(`/timelines/tag/${encoded}`);
    });

    it('uses the remote tag link of a trailing badge', () => {
      const html = '<p>本文<br><br><a href="https://remote.example/tags/fedibird" class="mention hashtag" rel="tag">#<span>fedibird</span></a></p>';
      const { container } = renderRemote({ html });
      const badge = container.querySelector('a.status__content__hashtag-badge');

      expect(badge).toHaveAttribute('href', 'https://remote.example/tags/fedibird');
      click(badge);

      expect(hrefAttr('View posts with #fedibird')).toBe('https://remote.example/tags/fedibird');
      expect(hrefAttr('View bob\'s posts with #fedibird')).toBeNull();
    });

    it('does not invent the origin URL for an out-of-band badge whose url is Fedibird\'s', () => {
      const html = '<p>本文</p>';
      const tags = [{ name: 'hidden', url: `${window.location.origin}/tags/hidden` }];
      const { container } = renderRemote({ html, tags });
      const badge = screen.getByRole('link', { name: '#hidden' });

      expect(container.querySelector('.status__content__hashtag-badge')).toBe(badge);
      click(badge);

      const browse = screen.getByRole('button', { name: 'View posts with #hidden' });
      const browseAccount = screen.getByRole('button', { name: 'View bob\'s posts with #hidden' });

      expect(browse).not.toHaveAttribute('href');
      expect(browseAccount).not.toHaveAttribute('href');
      expect(browse.getAttribute('href')).not.toBe('#');
      expect(browseAccount.getAttribute('href')).not.toBe('#');

      fireEvent.click(browse);
      expect(history.push).toHaveBeenLastCalledWith('/timelines/tag/hidden');

      click(badge);
      fireEvent.click(screen.getByRole('button', { name: 'View bob\'s posts with #hidden' }));
      expect(history.push).toHaveBeenLastCalledWith('/accounts/a1/posts/hidden');
    });

    it('has no hrefs when the remote account is not in the store', () => {
      const html = '<p>本文</p>';
      const tags = [{ name: 'hidden', url: `${window.location.origin}/tags/hidden` }];
      const store = createStore(reducer, initialState().deleteIn(['accounts', 'a1']), applyMiddleware(thunk));

      render(
        <Provider store={store}>
          <RouterProvider>
            <StatusContent
              status={buildStatus({ account: { id: 'a1', username: 'bob', acct: 'bob@remote.example' }, contentHtml: html, tags })}
              onTranslate={jest.fn()}
              onClick={jest.fn()}
            />
            <HashtagMenuController />
          </RouterProvider>
        </Provider>,
      );

      click(screen.getByRole('link', { name: '#hidden' }));

      expect(screen.getByRole('button', { name: 'View posts with #hidden' })).not.toHaveAttribute('href');
      expect(screen.getByRole('button', { name: 'View bob\'s posts with #hidden' })).not.toHaveAttribute('href');
    });

    it('uses tags[].account_url for the matching tag and keeps the in-app path', () => {
      const tag = 'ハッシュ';
      const encoded = encodeURIComponent(tag);
      const accountUrl = `https://remote.example/@bob/tagged/${encoded}`;
      const html = `<p><a href="https://evil.example/tags/${encoded}" class="mention hashtag" rel="tag">#<span>${tag}</span></a></p>`;
      const { container } = renderRemote({
        html,
        account: { ...remoteAccount, url: 'https://evil.example/@bob' },
        tags: [
          { name: 'other', url: 'https://remote.example/tags/other', account_url: 'https://remote.example/@bob/tagged/other' },
          { name: tag, url: `https://remote.example/tags/${encoded}`, account_url: accountUrl },
        ],
      });

      const link = container.querySelector('.status__content__text a.mention.hashtag');
      const modified = click(link, { ctrlKey: true });

      expect(modified.defaultPrevented).toBe(false);
      expect(history.push).not.toHaveBeenCalled();
      expect(screen.queryByRole('button', { name: `View posts with #${tag}` })).toBeNull();

      click(link);

      const browse = screen.getByRole('button', { name: `View posts with #${tag}` });
      const browseAccount = screen.getByRole('button', { name: `View bob's posts with #${tag}` });

      expect(browse).toHaveAttribute('href', `https://evil.example/tags/${encoded}`);
      expect(browseAccount).toHaveAttribute('href', accountUrl);
      expect(browseAccount.getAttribute('href')).not.toContain('evil.example');
      expect(browseAccount.getAttribute('href')).not.toContain('/web/');

      fireEvent.click(browseAccount);
      expect(history.push).toHaveBeenLastCalledWith(`/accounts/a1/posts/${encoded}`);
    });

    it('omits the remote href when the label is not on status.tags and still opens the in-app timeline', () => {
      const html = '<p><a href="https://remote.example/tags/rails" class="mention hashtag" rel="tag">#<span>rails</span></a></p>';
      const { container } = renderRemote({
        html,
        tags: [{ name: 'other', url: 'https://remote.example/tags/other', account_url: 'https://remote.example/@bob/tagged/other' }],
      });

      click(container.querySelector('.status__content__text a.mention.hashtag'));
      const browseAccount = screen.getByRole('button', { name: 'View bob\'s posts with #rails' });
      expect(browseAccount).not.toHaveAttribute('href');
      fireEvent.click(browseAccount);
      expect(history.push).toHaveBeenLastCalledWith('/accounts/a1/posts/rails');
    });

    it('matches a tag case-insensitively and ignores a tag that has no account_url', () => {
      const html = '<p><a href="https://remote.example/tags/Rails" class="mention hashtag" rel="tag">#<span>Rails</span></a></p>';
      const { container } = renderRemote({
        html,
        tags: [{ name: 'rails', url: 'https://example.test/tags/rails' }],
      });

      click(container.querySelector('.status__content__text a.mention.hashtag'));
      expect(screen.getByRole('button', { name: 'View bob\'s posts with #Rails' })).not.toHaveAttribute('href');
    });
  });

  describe('hrefs of local posts', () => {
    it('uses Fedibird public pages for out-of-band badges, even when the API url differs', () => {
      const html = '<p>本文</p>';
      const tags = [{ name: 'ハッシュ', url: 'https://elsewhere.example/tags/ignored' }];
      const { container } = renderMenu({ contentHtml: html, tags });
      const badge = container.querySelector('a.status__content__hashtag-badge');
      const encoded = encodeURIComponent('ハッシュ');

      click(badge);

      expect(screen.getByRole('button', { name: 'View posts with #ハッシュ' })).toHaveAttribute('href', `${window.location.origin}/tags/${encoded}`);
      expect(screen.getByRole('button', { name: 'View alice\'s posts with #ハッシュ' })).toHaveAttribute('href', `${window.location.origin}/@alice/tagged/${encoded}`);
    });

    it('uses the server account_url for a local tag when the status carries one', () => {
      const html = '<p>本文<br><br><a href="https://example.com/tags/mastodon" class="mention hashtag" rel="tag">#<span>mastodon</span></a></p>';
      const accountUrl = `${window.location.origin}/@alice/tagged/mastodon`;
      const { container } = renderMenu({
        contentHtml: html,
        tags: [{ name: 'mastodon', url: `${window.location.origin}/tags/mastodon`, account_url: accountUrl }],
      });

      click(container.querySelector('a.status__content__hashtag-badge'));
      expect(screen.getByRole('button', { name: 'View alice\'s posts with #mastodon' })).toHaveAttribute('href', accountUrl);
    });
  });

  it('does not open the status from the hashtag or from a menu action', () => {
    const { container, onClick } = renderMenu();
    const badge = container.querySelector('a.status__content__hashtag-badge');
    const content = container.querySelector('.status__content');
    const parentClick = jest.fn();
    content.addEventListener('click', parentClick);

    fireEvent.mouseDown(badge, { button: 0, clientX: 4, clientY: 4 });
    fireEvent.mouseUp(badge, { button: 0, clientX: 6, clientY: 5 });
    click(badge);
    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtag' }));

    expect(onClick).not.toHaveBeenCalled();
    expect(parentClick).not.toHaveBeenCalled();
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith('#mastodon');
    expect(history.push).not.toHaveBeenCalled();
  });

  it('adds a favourite tag once and shows the API error when creation fails', async () => {
    const { container, store } = renderMenu();
    const badge = container.querySelector('a.status__content__hashtag-badge');
    const inline = container.querySelector('.status__content__text a.mention.hashtag');

    store.dispatch(fetchFavouriteTagSuccess({ id: 'ft-existing', name: 'Mastodon', updated_at: '2020-01-01T00:00:00.000Z' }));
    click(badge);
    fireEvent.click(screen.getByRole('button', { name: 'Add to favorites' }));
    expect(mockApiPost).not.toHaveBeenCalled();

    click(inline);
    fireEvent.click(screen.getByRole('button', { name: 'Add to favorites' }));

    await waitFor(() => expect(mockApiPost).toHaveBeenCalledWith('/api/v1/favourite_tags', { name: 'test' }));
    await waitFor(() => expect(store.getState().getIn(['favourite_tags', 'ft1', 'name'])).toBe('test'));

    click(inline);
    fireEvent.click(screen.getByRole('button', { name: 'Add to favorites' }));
    expect(mockApiPost).toHaveBeenCalledTimes(1);

    mockApiPost.mockRejectedValueOnce({
      response: {
        status: 422,
        statusText: 'Unprocessable Entity',
        headers: {},
        data: { error: 'You have already favourite the maximum amount of hashtags' },
      },
    });
    const fedibird = screen.getByRole('link', { name: '#fedibird' });
    click(fedibird);
    fireEvent.click(screen.getByRole('button', { name: 'Add to favorites' }));

    await waitFor(() => expect(store.getState().getIn(['alerts', 0, 'message'])).toBe('You have already favourite the maximum amount of hashtags'));
  });

  it('copies one hashtag and every original hashtag in order without duplicates', () => {
    const { container } = renderMenu({
      status: buildStatus({
        translationMode: 'translated',
        translation,
      }),
    });
    const translated = container.querySelector('.status__content__text a.mention.hashtag');
    const badge = screen.getByRole('link', { name: '#fedibird' });

    expect(translated.textContent).toBe('#different');
    expect(screen.queryByRole('link', { name: '#Test' })).toBeNull();

    click(badge);
    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtag' }));
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith('#fedibird');

    click(translated);
    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtags' }));
    expect(navigator.clipboard.writeText).toHaveBeenLastCalledWith('#test #mastodon #fedibird');
    expect(navigator.clipboard.writeText).not.toHaveBeenCalledWith(expect.stringContaining('#different'));
  });

  it('uses the acct as the label when the account has no username', () => {
    const account = { id: 'a1', display_name: 'Alice', username: '', acct: 'alice@example.com', url: 'https://example.com/@alice' };
    const { container } = renderMenu({
      account,
      status: buildStatus({ account }),
    });

    click(container.querySelector('a.status__content__hashtag-badge'));

    expect(screen.getByRole('button', { name: 'View alice@example.com\'s posts with #mastodon' })).toBeInTheDocument();
    expect(container.querySelector('a.status__content__hashtag-badge')).toHaveAttribute('data-account-name', 'alice@example.com');
  });

  it('runs an open menu action from the keyboard', () => {
    const { container } = renderMenu();
    const badge = container.querySelector('a.status__content__hashtag-badge');

    click(badge);
    // React 16 drops keypress events whose charCode is 0, including a bare Enter.
    fireEvent.keyPress(screen.getByRole('button', { name: 'Copy hashtag' }), { key: 'Enter', charCode: 13, keyCode: 13 });

    expect(navigator.clipboard.writeText).toHaveBeenCalledWith('#mastodon');
  });

  it('opens the hashtag mute dialog and hides favourite and mute when signed out', () => {
    const signedIn = renderMenu();
    click(signedIn.container.querySelector('a.status__content__hashtag-badge'));
    const labels = Array.from(document.querySelectorAll('.dropdown-menu__container__list > li')).map(item => item.textContent);
    expect(labels).toEqual([
      'View posts with #mastodon',
      'View alice\'s posts with #mastodon',
      '',
      'Add to favorites',
      'Copy hashtag',
      'Copy hashtags',
      '',
      'Mute #mastodon',
    ]);
    const mute = screen.getByRole('button', { name: 'Mute #mastodon' });

    expect(mute).not.toHaveAttribute('href');
    expect(mute.closest('li').className).toContain('dropdown-menu__item--dangerous');

    fireEvent.click(mute);

    expect(window.open).not.toHaveBeenCalled();
    expect(history.push).not.toHaveBeenCalled();
    expect(signedIn.store.getState().getIn(['modal', 'modalType'])).toBe('HASHTAG_MUTE');
    expect(signedIn.store.getState().getIn(['modal', 'hashtag'])).toBe('mastodon');
    signedIn.unmount();

    const signedOut = renderMenu({ signedIn: false });
    click(signedOut.container.querySelector('.status__content__text a.mention.hashtag'));

    expect(screen.getByRole('button', { name: 'View posts with #test' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Copy hashtag' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Copy hashtags' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Add to favorites' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Mute #test' })).toBeNull();
  });

  it('opens the menu from an out-of-band badge and copies that tag with the original set', () => {
    const html = `<p>本文 ${anchor('FediBird')} です</p>`;
    const tags = [
      { name: 'fedibird', url: 'https://example.com/tags/fedibird' },
      { name: 'bar', url: 'https://example.com/tags/bar' },
    ];
    const { container } = renderMenu({
      contentHtml: html,
      tags,
      status: buildStatus({
        contentHtml: html,
        tags,
        translationMode: 'translated',
        translation,
      }),
    });
    const badge = screen.getByRole('link', { name: '#bar' });

    expect(container.querySelector('.status__content__text').textContent).toContain('#different');
    expect(container.querySelector('.status__content__hashtag-badge[data-menu-hashtag="fedibird"]')).toBeNull();
    expect(badge).toHaveAttribute('data-menu-hashtag', 'bar');
    expect(badge).toHaveAttribute('data-account-id', 'a1');
    expect(badge).toHaveAttribute('data-account-name', 'alice');
    expect(badge).toHaveAttribute('data-status-id', 's1');

    click(badge);

    expect(screen.getByRole('button', { name: 'View posts with #bar' })).toHaveAttribute('href', `${window.location.origin}/tags/bar`);
    expect(screen.getByRole('button', { name: 'View alice\'s posts with #bar' })).toHaveAttribute('href', `${window.location.origin}/@alice/tagged/bar`);
    expect(screen.getByRole('button', { name: 'Add to favorites' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Mute #bar' })).not.toHaveAttribute('href');
    expect(Overlay.lastTarget).toBe(badge);

    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtags' }));

    expect(navigator.clipboard.writeText).toHaveBeenCalledWith('#FediBird #bar');
    expect(navigator.clipboard.writeText).not.toHaveBeenCalledWith(expect.stringContaining('#different'));
  });

  it('projects hashtag menu labels while suppression is active and keeps the raw tag for actions', () => {
    const native = '👌';
    const tag = `party${native}`;
    const html = `<p>Hello ${anchor(tag)}</p>`;
    const { container, store } = renderMenu({
      signedIn: true,
      contentHtml: html,
      emojiMutes: {
        revision: '2',
        appliedRevision: '1',
        phase: 'stale',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'suppress',
      },
      status: buildStatus({ contentHtml: html, tags: [{ name: tag, url: `https://example.com/tags/${encodeURIComponent(tag)}` }] }),
    });

    const link = container.querySelector('a[data-menu-hashtag]');

    expect(link.textContent).toBe(`#party${'\u25FB'}`);
    expect(link.outerHTML).not.toContain(native);
    expect(hashtagMenuStoredName(link)).toBe(tag);
    click(link.querySelector('span') || link);

    const menu = document.querySelector('.dropdown-menu');
    const browse = screen.getByRole('button', { name: `View posts with #party${'\u25FB'}` });
    const account = screen.getByRole('button', { name: `View alice's posts with #party${'\u25FB'}` });

    expect(menu.textContent).not.toContain(native);
    expect(browse).not.toHaveAttribute('title', expect.stringContaining(native));
    expect(browse.getAttribute('aria-label') || browse.textContent).not.toContain(native);
    expect(browse).toHaveAttribute('href', `${window.location.origin}/tags/${encodeURIComponent(tag)}`);
    expect(account).toHaveAttribute('href', `${window.location.origin}/@alice/tagged/${encodeURIComponent(tag)}`);
    expect(browse.outerHTML).not.toContain(native);
    expect(hashtagMenuStoredName(link)).toBe(tag);

    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtag' }));
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(`#${tag}`);

    click(link.querySelector('span') || link);
    fireEvent.click(screen.getByRole('button', { name: `Mute #party${'\u25FB'}` }));
    expect(store.getState().getIn(['modal', 'hashtag'])).toBe(tag);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [],
      });
    });

    const restored = container.querySelector('a[data-menu-hashtag]');

    expect(restored.textContent).toBe(`#${tag}`);
    expect(restored.getAttribute('data-menu-hashtag')).toBe(tag);
    click(restored.querySelector('span') || restored);
    expect(screen.getByRole('button', { name: `View posts with #${tag}` })).toHaveAttribute('href', `${window.location.origin}/tags/${encodeURIComponent(tag)}`);
  });

  it('opens mute from a singular /tag/ URL with the original tag, not the projected label', () => {
    const native = '👍';
    const tag = `party${native}`;
    const href = `https://remote.example/tag/${encodeURIComponent(tag)}`;
    const html = `<p>Hello <a href="${href}" class="mention hashtag" rel="tag">#<span>${tag}</span></a></p>`;
    const { container, store } = renderMenu({
      signedIn: true,
      contentHtml: html,
      emojiMutes: {
        revision: '2',
        appliedRevision: '1',
        phase: 'stale',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'suppress',
      },
      status: buildStatus({ contentHtml: html, tags: [{ name: tag, url: href }] }),
    });
    const link = container.querySelector('a[data-menu-hashtag]');

    expect(link.textContent).toBe(`#party${'\u25FB'}`);
    expect(link.outerHTML).not.toContain(native);
    expect(hashtagMenuStoredName(link)).toBe(tag);
    click(link.querySelector('span') || link);
    fireEvent.click(screen.getByRole('button', { name: `Mute #party${'\u25FB'}` }));
    expect(store.getState().getIn(['modal', 'hashtag'])).toBe(tag);
    expect(store.getState().getIn(['modal', 'hashtag'])).not.toContain('\u25FB');
  });

  it('opens the in-app menu for body hashtags named tag and tags without status.tags', () => {
    const routes = ['/tags/tag', '/tags/tags', '/tag/tag', '/tag/tags'];
    const html = `<p>before ${routes.map(path => {
      const name = path.split('/').pop();

      return `<a href="https://example.com${path}" class="mention hashtag" rel="tag">#<span>${name}</span></a>`;
    }).join(' mid ')} after</p>`;
    const { container } = renderMenu({
      signedIn: true,
      contentHtml: html,
      status: buildStatus({ contentHtml: html, tags: [] }),
    });
    const links = container.querySelectorAll('a.mention.hashtag');

    expect(links).toHaveLength(4);
    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();

    links.forEach((link, index) => {
      const name = routes[index].split('/').pop();

      expect(link.getAttribute('data-menu-hashtag')).toBe(name);
      expect(link.getAttribute('href')).toBe(`https://example.com${routes[index]}`);
      expect(link.textContent).not.toContain('\u25FB');

      const plain = click(link.querySelector('span') || link);

      expect(plain.defaultPrevented).toBe(true);
      expect(screen.getByRole('button', { name: `View posts with #${name}` })).toBeTruthy();
      click(link.querySelector('span') || link);

      const modified = click(link.querySelector('span') || link, { ctrlKey: true });

      expect(modified.defaultPrevented).toBe(false);
      expect(link.getAttribute('href')).toBe(`https://example.com${routes[index]}`);
    });
  });

  it('opens a non-tag route from the stored hashtag text and keeps an unnamed link ordinary', () => {
    const native = '👍';
    const tag = `party${native}`;
    const topic = 'https://remote.example/topics/gardening';
    const emojiTopic = `https://remote.example/topics/${encodeURIComponent(tag)}`;
    const unnamed = 'https://remote.example/topics/mystery';
    const html = `<p>before <a href="${topic}" class="mention hashtag" rel="tag">#<span>gardening</span></a> mid <a href="${emojiTopic}" class="mention hashtag" rel="tag">#<span>${tag}</span></a> and <a href="${unnamed}" class="mention hashtag" rel="tag">#</a> after</p>`;
    const { container, store } = renderMenu({
      signedIn: true,
      contentHtml: html,
      emojiMutes: {
        revision: '2',
        appliedRevision: '1',
        phase: 'stale',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'suppress',
      },
      status: buildStatus({ contentHtml: html, tags: [] }),
    });
    const links = container.querySelectorAll('a.mention.hashtag');
    const gardening = links[0];
    const emoji = links[1];
    const plain = links[2];
    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();
    expect(gardening.getAttribute('data-menu-hashtag')).toBe('gardening');
    expect(gardening.getAttribute('href')).toBe(topic);
    expect(hashtagMenuStoredName(emoji)).toBe(tag);
    expect(emoji.getAttribute('href')).toBe(emojiTopic);
    expect(emoji.textContent).toBe(`#party${'\u25FB'}`);
    expect(emoji.outerHTML).not.toContain(native);
    expect(emoji.getAttribute('title') || '').not.toContain(native);
    expect(emoji.getAttribute('aria-label') || '').not.toContain(native);
    expect(plain.hasAttribute('data-menu-hashtag')).toBe(false);
    expect(plain.getAttribute('href')).toBe(unnamed);

    const open = click(gardening.querySelector('span') || gardening);

    expect(open.defaultPrevented).toBe(true);
    expect(screen.getByRole('button', { name: 'View posts with #gardening' })).toBeTruthy();
    click(gardening.querySelector('span') || gardening);

    const modified = click(gardening, { ctrlKey: true });

    expect(modified.defaultPrevented).toBe(false);
    expect(gardening.getAttribute('href')).toBe(topic);

    click(emoji.querySelector('span') || emoji);
    expect(screen.getByRole('button', { name: `View posts with #party${'\u25FB'}` })).toBeTruthy();
    expect(document.querySelector('.dropdown-menu').textContent).not.toContain(native);
    fireEvent.click(screen.getByRole('button', { name: `Mute #party${'\u25FB'}` }));
    expect(store.getState().getIn(['modal', 'hashtag'])).toBe(tag);

    const ordinary = click(plain);

    expect(ordinary.defaultPrevented).toBe(false);
    expect(plain.getAttribute('href')).toBe(unnamed);
    expect(screen.queryByRole('button', { name: 'View posts with #' })).toBeNull();
  });

  it('reuses one original hashtag name for both bilingual blocks', () => {
    const native = '👍';
    const tag = `party${native}`;
    const href = `https://remote.example/topics/${encodeURIComponent(tag)}`;
    const sourceHtml = `<p>See the garden <a href="${href}" class="mention hashtag" rel="tag">#<span>${tag}</span></a> today</p>`;
    const targetHtml = `<p>庭を見て <a href="${href}" class="mention hashtag" rel="tag">#<span>園芸</span></a> ください</p>`;
    const { container, store } = renderMenu({
      signedIn: true,
      emojiMutes: {
        revision: '2',
        appliedRevision: '1',
        phase: 'stale',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'suppress',
      },
      status: buildStatus({
        contentHtml: sourceHtml,
        language: 'en',
        tags: [],
        translationMode: 'bilingual',
        translation: {
          contentHtml: targetHtml,
          spoilerHtml: '',
          language: 'ja',
          detected_source_language: 'en',
          requested_source_language: 'en',
          requested_target_language: 'ja',
          provider: 'test',
        },
      }),
    });
    const source = container.querySelector('.status-translation-pair__source a.mention.hashtag');
    const target = container.querySelector('.status-translation-pair__target a.mention.hashtag');

    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();
    expect(source.textContent).toBe(`#party${'\u25FB'}`);
    expect(target.textContent).toBe('#園芸');
    [source, target].forEach(link => {
      expect(link.getAttribute('href')).toBe(href);
      expect(hashtagMenuStoredName(link)).toBe(tag);
      expect(link.outerHTML).not.toContain(native);
      expect(link.getAttribute('title') || '').not.toContain(native);
      expect(link.getAttribute('aria-label') || '').not.toContain(native);

      const open = click(link.querySelector('span') || link);

      expect(open.defaultPrevented).toBe(true);
      expect(screen.getByRole('button', { name: `Mute #party${'\u25FB'}` })).toBeTruthy();
      expect(document.querySelector('.dropdown-menu').textContent).not.toContain(native);
      expect(document.querySelector('.dropdown-menu').textContent).not.toContain('園芸');
      fireEvent.click(screen.getByRole('button', { name: `Mute #party${'\u25FB'}` }));
      expect(store.getState().getIn(['modal', 'hashtag'])).toBe(tag);
    });
  });

  it.each(['translated', 'bilingual', 'original'])('keeps reordered shared-href hashtags on the %s view', mode => {
    const href = 'https://remote.example/topics/common';
    const sourceHtml = `<p>First <a href="${href}" class="mention hashtag" rel="tag">#<span>alpha</span></a> then <a href="${href}" class="mention hashtag" rel="tag">#<span>beta</span></a> stays</p>`;
    const targetHtml = `<p>後で <a href="${href}" class="mention hashtag" rel="tag">#<span>ベータ</span></a> 先に <a href="${href}" class="mention hashtag" rel="tag">#<span>アルファ</span></a> です</p>`;
    const { container, store } = renderMenu({
      signedIn: true,
      emojiMutes: {
        revision: '2',
        appliedRevision: '1',
        phase: 'stale',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'suppress',
      },
      status: buildStatus({
        contentHtml: sourceHtml,
        language: 'en',
        tags: [],
        translationMode: mode,
        translation: {
          contentHtml: targetHtml,
          spoilerHtml: '',
          language: 'ja',
          detected_source_language: 'en',
          requested_source_language: 'en',
          requested_target_language: 'ja',
          provider: 'test',
        },
      }),
    });
    const expectOrdinary = link => {
      expect(link.getAttribute('href')).toBe(href);
      expect(link.hasAttribute('data-menu-hashtag')).toBe(false);
      expect(link.outerHTML).not.toContain('alpha');
      expect(link.outerHTML).not.toContain('beta');

      const modified = click(link.querySelector('span') || link, { ctrlKey: true });
      const open = click(link.querySelector('span') || link);

      expect(modified.defaultPrevented).toBe(false);
      expect(open.defaultPrevented).toBe(false);
      expect(link.getAttribute('href')).toBe(href);
    };
    const expectNamed = (link, name) => {
      expect(link.getAttribute('href')).toBe(href);
      expect(link.getAttribute('data-menu-hashtag')).toBe(name);

      const modified = click(link.querySelector('span') || link, { ctrlKey: true });

      expect(modified.defaultPrevented).toBe(false);
      expect(screen.queryByRole('button', { name: `Mute #${name}` })).toBeNull();
      expect(link.getAttribute('href')).toBe(href);

      const open = click(link.querySelector('span') || link);

      expect(open.defaultPrevented).toBe(true);
      fireEvent.click(screen.getByRole('button', { name: `Mute #${name}` }));
      expect(store.getState().getIn(['modal', 'hashtag'])).toBe(name);

      const again = click(link.querySelector('span') || link);

      expect(again.defaultPrevented).toBe(true);
      fireEvent.click(screen.getByRole('button', { name: 'Copy hashtag' }));
      expect(navigator.clipboard.writeText).toHaveBeenLastCalledWith(`#${name}`);
    };

    if (mode === 'translated') {
      const links = container.querySelectorAll('.status__content__text a.mention.hashtag');

      expect(container.querySelector('.status-translation-pair')).toBeNull();
      expect(links).toHaveLength(2);
      links.forEach(expectOrdinary);
      expect(screen.queryByRole('button', { name: 'Mute #alpha' })).toBeNull();
      expect(screen.queryByRole('button', { name: 'Mute #beta' })).toBeNull();
      return;
    }

    if (mode === 'bilingual') {
      const source = container.querySelectorAll('.status-translation-pair__source a.mention.hashtag');
      const target = container.querySelectorAll('.status-translation-pair__target a.mention.hashtag');

      expect(source).toHaveLength(2);
      expect(target).toHaveLength(2);
      expectNamed(source[0], 'alpha');
      expectNamed(source[1], 'beta');
      target.forEach(expectOrdinary);
      return;
    }

    const links = container.querySelectorAll('.status__content__text a.mention.hashtag');

    expect(container.querySelector('.status-translation-pair')).toBeNull();
    expect(links).toHaveLength(2);
    expect(links[0].textContent).toBe('#alpha');
    expect(links[1].textContent).toBe('#beta');
    expectNamed(links[0], 'alpha');
    expectNamed(links[1], 'beta');
  });

  it('keeps a raw hashtag emoji out of the DOM during suppress and restores the original name', () => {
    const native = '👍';
    const tag = `party${native}`;
    const badgeTag = `wave${native}`;
    const inlineHref = 'https://remote.example/topics/party';
    const badgeHref = 'https://remote.example/topics/wave';
    const cwHref = 'https://remote.example/topics/party-cw';
    const plainHref = 'https://remote.example/topics/garden';
    const sourceHtml = `<p>Hello <a href="${inlineHref}" class="mention hashtag" rel="tag">#<span>${tag}</span></a> and <a href="${plainHref}" class="mention hashtag" rel="tag">#<span>garden</span></a> stays<br><br><a href="${badgeHref}" class="mention hashtag" rel="tag">#<span>${badgeTag}</span></a></p>`;
    const spoilerHtml = `<p>CW <a href="${cwHref}" class="mention hashtag" rel="tag">#<span>${tag}</span></a> note</p>`;
    const targetHtml = `<p>訳 <a href="${inlineHref}" class="mention hashtag" rel="tag">#<span>パーティ</span></a> です</p>`;
    const targetSpoiler = `<p>警告 <a href="${cwHref}" class="mention hashtag" rel="tag">#<span>パーティ</span></a> 注</p>`;
    const { container, store } = renderMenu({
      signedIn: true,
      emojiMutes: {
        revision: '2',
        appliedRevision: '1',
        phase: 'stale',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'suppress',
      },
      status: buildStatus({
        contentHtml: sourceHtml,
        spoilerHtml,
        spoiler_text: 'CW note',
        language: 'en',
        tags: [],
        translationMode: 'bilingual',
        translation: {
          contentHtml: targetHtml,
          spoilerHtml: targetSpoiler,
          language: 'ja',
          detected_source_language: 'en',
          requested_source_language: 'en',
          requested_target_language: 'ja',
          provider: 'test',
        },
      }),
    });
    const expectConcealed = node => {
      expect(node).toBeTruthy();
      expect(node.outerHTML).not.toContain(native);
      Array.from(node.attributes).forEach(attribute => {
        if (attribute.name.indexOf('data-') === 0 || attribute.name === 'title' || attribute.name.indexOf('aria-') === 0) {
          expect(attribute.value).not.toContain(native);
        }
      });
      expect(node.getAttribute('title') || '').not.toContain(native);
      expect(node.getAttribute('aria-label') || '').not.toContain(native);
    };
    const byHref = href => container.querySelectorAll(`a[href="${href}"]`);

    expect(byHref(inlineHref).length).toBe(2);
    expect(byHref(cwHref).length).toBe(2);
    byHref(inlineHref).forEach(expectConcealed);
    byHref(cwHref).forEach(expectConcealed);
    fireEvent.click(screen.getByRole('button', { name: 'Show more' }));

    const badge = container.querySelector('a.status__content__hashtag-badge');

    expectConcealed(badge);
    expect(badge.getAttribute('href')).toBe(badgeHref);
    expect(hashtagMenuStoredName(badge)).toBe(badgeTag);
    byHref(inlineHref).forEach(link => {
      expect(hashtagMenuStoredName(link)).toBe(tag);
    });

    const garden = container.querySelector(`a[href="${plainHref}"]`);

    expect(garden.getAttribute('data-menu-hashtag')).toBe('garden');
    expect(click(garden, { ctrlKey: true }).defaultPrevented).toBe(false);
    expect(click(garden).defaultPrevented).toBe(true);
    expect(screen.getByRole('button', { name: 'Mute #garden' })).toBeTruthy();
    click(garden);

    const inline = container.querySelector(`.status-translation-pair__source a[href="${inlineHref}"]`);

    expect(click(inline, { ctrlKey: true }).defaultPrevented).toBe(false);
    expect(inline.getAttribute('href')).toBe(inlineHref);
    expect(click(inline).defaultPrevented).toBe(true);
    expect(document.querySelector('.dropdown-menu').outerHTML).not.toContain(native);
    fireEvent.click(screen.getByRole('button', { name: `Mute #party${'\u25FB'}` }));
    expect(store.getState().getIn(['modal', 'hashtag'])).toBe(tag);
    expect(store.getState().getIn(['modal', 'hashtag'])).not.toContain('\u25FB');

    let beforeCommit = null;

    const unsubscribe = store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'revision']) === '3' && store.getState().getIn(['emojiMutes', 'phase']) === 'stale') {
        beforeCommit = container.querySelector('.status__content').outerHTML;
      }
    });

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [],
      });
    });
    unsubscribe();

    expect(beforeCommit).not.toBeNull();
    expect(beforeCommit).not.toContain(native);

    const verified = container.querySelector(`.status-translation-pair__source a[href="${inlineHref}"]`);

    expect(verified.getAttribute('data-menu-hashtag')).toBe(tag);
    expect(verified.textContent).toContain(native);
    expect(click(verified).defaultPrevented).toBe(true);
    fireEvent.click(screen.getByRole('button', { name: `Mute #${tag}` }));
    expect(store.getState().getIn(['modal', 'hashtag'])).toBe(tag);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_FAIL, failure: 'unavailable' });
    });

    const failed = container.querySelector(`.status-translation-pair__source a[href="${inlineHref}"]`);

    expectConcealed(failed);
    expect(hashtagMenuStoredName(failed)).toBe(tag);
    expect(click(failed).defaultPrevented).toBe(true);
    fireEvent.click(screen.getByRole('button', { name: `Mute #party${'\u25FB'}` }));
    expect(store.getState().getIn(['modal', 'hashtag'])).toBe(tag);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    const ignored = container.querySelector(`.status-translation-pair__source a[href="${inlineHref}"]`);

    expect(ignored.getAttribute('data-menu-hashtag')).toBe(tag);
    expect(ignored.textContent).toContain(native);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_ENABLE });
    });

    expectConcealed(container.querySelector(`.status-translation-pair__source a[href="${inlineHref}"]`));

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });

    const disabled = container.querySelector(`.status-translation-pair__source a[href="${inlineHref}"]`);

    expect(disabled.getAttribute('data-menu-hashtag')).toBe(tag);
    expect(disabled.textContent).toContain(native);
    expect(container.querySelector(`a[href="${plainHref}"]`).getAttribute('data-menu-hashtag')).toBe('garden');
  });

  it('does not treat a plain hmtoken-1 tag as the concealed party emoji', async () => {
    const native = '👍';
    const tag = `party${native}`;
    const plain = 'hmtoken-1';
    const emojiHref = 'https://remote.example/topics/party';
    const plainHref = `https://remote.example/tags/${plain}`;
    const html = `<p>First <a href="${emojiHref}" class="mention hashtag" rel="tag">#<span>${tag}</span></a> then <a href="${plainHref}" class="mention hashtag" rel="tag">#<span>${plain}</span></a> stays</p>`;
    const { container, store } = renderMenu({
      signedIn: true,
      contentHtml: html,
      emojiMutes: {
        revision: '2',
        appliedRevision: '1',
        phase: 'stale',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'suppress',
      },
      status: buildStatus({ contentHtml: html, tags: [] }),
    });
    const emoji = container.querySelector(`a[href="${emojiHref}"]`);
    const literal = container.querySelector(`a[href="${plainHref}"]`);

    expect(emoji.hasAttribute('data-menu-hashtag-token')).toBe(true);
    expect(emoji.getAttribute('data-menu-hashtag')).toBe('');
    expect(hashtagMenuStoredName(emoji)).toBe(tag);
    expect(emoji.outerHTML).not.toContain(native);
    expect(literal.hasAttribute('data-menu-hashtag-token')).toBe(false);
    expect(literal.getAttribute('data-menu-hashtag')).toBe(plain);
    expect(literal.outerHTML).not.toContain(native);

    const openEmoji = click(emoji.querySelector('span') || emoji);

    expect(openEmoji.defaultPrevented).toBe(true);
    expect(screen.getByRole('button', { name: `View posts with #party${'\u25FB'}` }).outerHTML).not.toContain(native);
    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtag' }));
    expect(navigator.clipboard.writeText).toHaveBeenLastCalledWith(`#${tag}`);
    click(emoji.querySelector('span') || emoji);
    fireEvent.click(screen.getByRole('button', { name: `Mute #party${'\u25FB'}` }));
    expect(store.getState().getIn(['modal', 'hashtag'])).toBe(tag);
    click(emoji.querySelector('span') || emoji);
    fireEvent.click(screen.getByRole('button', { name: 'Add to favorites' }));
    await waitFor(() => expect(mockApiPost).toHaveBeenCalledWith('/api/v1/favourite_tags', { name: tag }));

    const openPlain = click(literal.querySelector('span') || literal);

    expect(openPlain.defaultPrevented).toBe(true);
    expect(screen.getByRole('button', { name: 'View posts with #hmtoken-1' })).toBeTruthy();
    expect(document.querySelector('.dropdown-menu').outerHTML).not.toContain(native);
    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtag' }));
    expect(navigator.clipboard.writeText).toHaveBeenLastCalledWith('#hmtoken-1');
    click(literal.querySelector('span') || literal);
    fireEvent.click(screen.getByRole('button', { name: 'Mute #hmtoken-1' }));
    expect(store.getState().getIn(['modal', 'hashtag'])).toBe(plain);
    click(literal.querySelector('span') || literal);
    fireEvent.click(screen.getByRole('button', { name: 'Add to favorites' }));
    await waitFor(() => expect(mockApiPost).toHaveBeenCalledWith('/api/v1/favourite_tags', { name: plain }));
  });

  it('keeps an emojified suffix in the hashtag identity from the stored html', async () => {
    const native = '👍';
    const href = 'https://remote.example/topics/party';
    const custom = '<img class="emojione custom-emoji" alt=":blob:" title="blob" src="https://cdn.example/blob.svg" data-shortcode="blob">';
    const html = `<p>See <a href="${href}" class="mention hashtag" rel="tag">#${emojify(`<span>party${native}</span>`)}</a> and <a href="https://remote.example/topics/custom" class="mention hashtag" rel="tag">#<span>party${custom}</span></a> stays</p>`;
    const { container, store } = renderMenu({
      signedIn: true,
      contentHtml: html,
      emojiMutes: {
        revision: '2',
        appliedRevision: '1',
        phase: 'stale',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'suppress',
      },
      status: buildStatus({ contentHtml: html, tags: [] }),
    });
    const unicode = container.querySelector(`a[href="${href}"]`);
    const customLink = container.querySelector('a[href="https://remote.example/topics/custom"]');

    expect(hashtagMenuStoredName(unicode)).toBe(`party${native}`);
    expect(unicode.getAttribute('data-menu-hashtag') || '').not.toContain(native);
    expect(unicode.outerHTML).not.toContain(native);
    expect(hashtagMenuStoredName(customLink)).toBe('party:blob:');
    expect(customLink.getAttribute('data-menu-hashtag')).toBe('party:blob:');
    expect(customLink.querySelector('img')).toBeNull();
    expect(customLink.outerHTML).not.toContain('cdn.example/blob.svg');

    const clipboardCalls = navigator.clipboard.writeText.mock.calls.length;

    click(unicode);
    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtag' }));
    expect(navigator.clipboard.writeText.mock.calls.length).toBe(clipboardCalls + 1);
    expect(navigator.clipboard.writeText).toHaveBeenLastCalledWith(`#party${native}`);
    click(unicode);
    fireEvent.click(screen.getByRole('button', { name: `Mute #party${'\u25FB'}` }));
    expect(store.getState().getIn(['modal', 'hashtag'])).toBe(`party${native}`);
  });

  it('matches shared-href names across original paragraphs and not inside one pair', () => {
    const href = 'https://remote.example/topics/common';
    const sourceHtml = `<p>First <a href="${href}" class="mention hashtag" rel="tag">#<span>alpha</span></a> stays</p><p>Second <a href="${href}" class="mention hashtag" rel="tag">#<span>beta</span></a> stays</p>`;
    const targetHtml = `<p>後で <a href="${href}" class="mention hashtag" rel="tag">#<span>ベータ</span></a> です</p><p>先に <a href="${href}" class="mention hashtag" rel="tag">#<span>アルファ</span></a> です</p>`;
    const { container, store } = renderMenu({
      signedIn: true,
      status: buildStatus({
        contentHtml: sourceHtml,
        language: 'en',
        tags: [],
        translationMode: 'bilingual',
        translation: {
          contentHtml: targetHtml,
          spoilerHtml: '',
          language: 'ja',
          detected_source_language: 'en',
          requested_source_language: 'en',
          requested_target_language: 'ja',
          provider: 'test',
        },
      }),
    });
    const sources = container.querySelectorAll('.status-translation-pair__source a.mention.hashtag');
    const targets = container.querySelectorAll('.status-translation-pair__target a.mention.hashtag');

    expect(container.querySelectorAll('.status-translation-pair')).toHaveLength(2);
    expect(sources).toHaveLength(2);
    expect(targets).toHaveLength(2);
    expect(sources[0].getAttribute('data-menu-hashtag')).toBe('alpha');
    expect(sources[1].getAttribute('data-menu-hashtag')).toBe('beta');
    targets.forEach(link => {
      expect(link.hasAttribute('data-menu-hashtag')).toBe(false);
      expect(link.getAttribute('href')).toBe(href);
      expect(click(link, { ctrlKey: true }).defaultPrevented).toBe(false);
      expect(click(link).defaultPrevented).toBe(false);
    });

    ['alpha', 'beta'].forEach((name, index) => {
      const link = sources[index];

      expect(click(link, { ctrlKey: true }).defaultPrevented).toBe(false);
      expect(link.getAttribute('href')).toBe(href);
      click(link);
      fireEvent.click(screen.getByRole('button', { name: 'Copy hashtag' }));
      expect(navigator.clipboard.writeText).toHaveBeenLastCalledWith(`#${name}`);
      click(link);
      fireEvent.click(screen.getByRole('button', { name: `Mute #${name}` }));
      expect(store.getState().getIn(['modal', 'hashtag'])).toBe(name);
    });
  });

  it('rebinds a trailing badge that was already mounted when display enters suppress', async () => {
    const native = '👍';
    const wave = `wave${native}`;
    const gamma = `gamma${native}`;
    const party = `party${native}`;
    const link = (href, name) => `<a href="${href}" class="mention hashtag" rel="tag">#<span>${name}</span></a>`;
    const waveHref = 'https://remote.example/topics/wave';
    const gammaHref = 'https://remote.example/topics/gamma';
    const gardenHref = 'https://remote.example/topics/garden';
    const cwHref = 'https://remote.example/topics/party-cw';
    const sourceHtml = `<p>Hello ${link(gardenHref, 'garden')} stays<br><br>${link(waveHref, wave)} ${link('https://remote.example/topics/alpha', 'alpha')} ${link('https://remote.example/topics/beta', 'beta')} ${link(gammaHref, gamma)} ${link('https://remote.example/topics/delta', 'delta')}</p>`;
    const spoilerHtml = `<p>CW ${link(cwHref, party)} note</p>`;
    const targetHtml = `<p>庭 ${link(gardenHref, '庭園')} です</p>`;
    const { container, store } = renderMenu({
      signedIn: true,
      emojiMutes: {
        revision: '1',
        appliedRevision: '1',
        phase: 'ready',
        failure: null,
        rules: [],
        availability: 'enabled',
        display: 'apply',
      },
      status: buildStatus({
        contentHtml: sourceHtml,
        spoilerHtml,
        spoiler_text: 'CW note',
        language: 'en',
        tags: [],
        translationMode: 'bilingual',
        translation: {
          contentHtml: targetHtml,
          spoilerHtml: '',
          language: 'ja',
          detected_source_language: 'en',
          requested_source_language: 'en',
          requested_target_language: 'ja',
          provider: 'test',
        },
      }),
    });
    const useMenu = async (node, label, payload) => {
      const clipboardCalls = navigator.clipboard.writeText.mock.calls.length;
      const postCalls = mockApiPost.mock.calls.length;

      act(() => {
        store.dispatch({ type: 'MODAL_OPEN', modalType: 'TEST', modalProps: { hashtag: `unset-${payload}` } });
      });
      click(node);
      expect(screen.getByRole('button', { name: `View posts with #${label}` })).toBeTruthy();
      fireEvent.click(screen.getByRole('button', { name: 'Copy hashtag' }));
      expect(navigator.clipboard.writeText.mock.calls.length).toBe(clipboardCalls + 1);
      expect(navigator.clipboard.writeText).toHaveBeenLastCalledWith(`#${payload}`);
      click(node);
      fireEvent.click(screen.getByRole('button', { name: `Mute #${label}` }));
      expect(store.getState().getIn(['modal', 'hashtag'])).toBe(payload);
      click(node);
      fireEvent.click(screen.getByRole('button', { name: 'Add to favorites' }));

      const alreadySaved = store.getState().getIn(['favourite_tags']) && store.getState().get('favourite_tags').some(tag => tag.get('name') === payload);

      if (alreadySaved) {
        expect(mockApiPost.mock.calls.length).toBe(postCalls);
      } else {
        await waitFor(() => expect(mockApiPost.mock.calls.length).toBe(postCalls + 1));
        expect(mockApiPost).toHaveBeenLastCalledWith('/api/v1/favourite_tags', { name: payload });
      }
    };

    fireEvent.click(screen.getByRole('button', { name: 'Show more' }));
    expect(container.querySelectorAll('a.status__content__hashtag-badge')).toHaveLength(3);
    fireEvent.click(container.querySelector('.status__content__hashtag-more'));

    const badge = container.querySelector(`a.status__content__hashtag-badge[href="${waveHref}"]`);
    const later = container.querySelector(`a.status__content__hashtag-badge[href="${gammaHref}"]`);

    expect(container.querySelectorAll('a.status__content__hashtag-badge')).toHaveLength(5);
    expect(badge.hasAttribute('data-menu-hashtag-token')).toBe(false);
    expect(badge.getAttribute('data-menu-hashtag')).toBe(wave);
    expect(badge.textContent).toContain(native);
    await useMenu(badge, wave, wave);

    container.className = 'emoji-mutes-privacy-portal';
    const guard = createUnverifiedEmojiGuard();
    const stopGuard = store.subscribe(() => guard(store.getState()));
    let beforeCommit = null;
    const stopWatch = store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'display']) === 'suppress' && !beforeCommit) {
        beforeCommit = badge.getAttribute('data-menu-hashtag');
      }
    });

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });
    stopGuard();
    stopWatch();

    expect(beforeCommit).toBe('');
    expect(beforeCommit).not.toContain(native);

    expect(container.querySelector(`a.status__content__hashtag-badge[href="${waveHref}"]`)).toBe(badge);
    expect(container.querySelector(`a.status__content__hashtag-badge[href="${gammaHref}"]`)).toBe(later);
    expect(badge.hasAttribute('data-menu-hashtag-token')).toBe(true);
    expect(later.hasAttribute('data-menu-hashtag-token')).toBe(true);
    const cw = container.querySelector(`a[href="${cwHref}"]`);
    const garden = container.querySelector(`.status__content__text a[href="${gardenHref}"]`);

    expect(badge.outerHTML).not.toContain(native);
    expect(later.outerHTML).not.toContain(native);
    expect(cw.outerHTML).not.toContain(native);
    expect(hashtagMenuStoredName(badge)).toBe(wave);
    expect(hashtagMenuStoredName(later)).toBe(gamma);
    expect(hashtagMenuStoredName(cw)).toBe(party);
    expect(cw.hasAttribute('data-menu-hashtag-token')).toBe(true);
    expect(garden.hasAttribute('data-menu-hashtag-token')).toBe(false);
    expect(garden.getAttribute('data-menu-hashtag')).toBe('garden');
    expect(container.querySelector('.status-translation-pair__target a').getAttribute('data-menu-hashtag')).toBe('garden');
    await useMenu(badge, `wave${'\u25FB'}`, wave);
    click(garden);
    expect(screen.getByRole('button', { name: 'View posts with #garden' })).toBeTruthy();
    click(garden);

    const restored = () => {
      const node = container.querySelector(`a.status__content__hashtag-badge[href="${waveHref}"]`);

      expect(node).toBe(badge);
      expect(node.hasAttribute('data-menu-hashtag-token')).toBe(false);
      expect(node.getAttribute('data-menu-hashtag')).toBe(wave);
      expect(node.textContent).toContain(native);
    };

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [],
      });
    });
    restored();

    const concealAgain = () => {
      act(() => {
        store.dispatch({ type: EMOJI_MUTES_ENABLE });
      });
      expect(badge.hasAttribute('data-menu-hashtag-token')).toBe(true);
      expect(badge.outerHTML).not.toContain(native);
      expect(badge.getAttribute('data-menu-hashtag') || '').not.toContain(native);
    };

    concealAgain();
    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });
    restored();

    concealAgain();
    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });
    restored();

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_ENABLE });
      store.dispatch({ type: EMOJI_MUTES_FAIL, failure: 'unavailable' });
    });

    expect(badge.hasAttribute('data-menu-hashtag-token')).toBe(true);
    expect(badge.outerHTML).not.toContain(native);
    expect(badge.getAttribute('title') || '').not.toContain(native);
    expect(badge.getAttribute('aria-label') || '').not.toContain(native);
    expect(hashtagMenuStoredName(badge)).toBe(wave);
    await useMenu(badge, `wave${'\u25FB'}`, wave);
  });
});
