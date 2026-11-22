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
import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
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
    expect(link.getAttribute('data-menu-hashtag')).toBe(tag);
    click(link.querySelector('span') || link);

    const menu = document.querySelector('.dropdown-menu');
    const browse = screen.getByRole('button', { name: `View posts with #party${'\u25FB'}` });
    const account = screen.getByRole('button', { name: `View alice's posts with #party${'\u25FB'}` });

    expect(menu.textContent).not.toContain(native);
    expect(browse).not.toHaveAttribute('title', expect.stringContaining(native));
    expect(browse.getAttribute('aria-label') || browse.textContent).not.toContain(native);
    expect(browse).toHaveAttribute('href', `${window.location.origin}/tags/${encodeURIComponent(tag)}`);
    expect(account).toHaveAttribute('href', `${window.location.origin}/@alice/tagged/${encodeURIComponent(tag)}`);
    expect(link.getAttribute('data-menu-hashtag')).toBe(tag);

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
    expect(link.getAttribute('data-menu-hashtag')).toBe(tag);
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
    const withoutIdentity = emoji.cloneNode(true);

    withoutIdentity.removeAttribute('data-menu-hashtag');

    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();
    expect(gardening.getAttribute('data-menu-hashtag')).toBe('gardening');
    expect(gardening.getAttribute('href')).toBe(topic);
    expect(emoji.getAttribute('data-menu-hashtag')).toBe(tag);
    expect(emoji.getAttribute('href')).toBe(emojiTopic);
    expect(emoji.textContent).toBe(`#party${'\u25FB'}`);
    expect(withoutIdentity.outerHTML).not.toContain(native);
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
      const visible = link.cloneNode(true);

      visible.removeAttribute('data-menu-hashtag');
      expect(link.getAttribute('href')).toBe(href);
      expect(link.getAttribute('data-menu-hashtag')).toBe(tag);
      expect(visible.outerHTML).not.toContain(native);
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
});
