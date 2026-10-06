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
import favouriteTagsReducer from 'mastodon/reducers/favourite_tags';
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

const contentHtml = `<p>See ${anchor('test')} today ${anchor('mastodon')} ${anchor('Test')} ${anchor('fedibird')}</p>`;

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
  const next = state.set('favourite_tags', favouriteTagsReducer(state.get('favourite_tags'), action));

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
      a1: { id: 'a1', display_name: 'Alice', username: 'alice', acct: 'alice' },
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

function renderMenu({ status = buildStatus(), signedIn, onClick = jest.fn(), account } = {}) {
  const state = account ? initialState().setIn(['accounts', 'a1'], fromJS(account)) : initialState();
  const store = createStore(reducer, state, applyMiddleware(thunk));
  const view = render(
    <Provider store={store}>
      <RouterProvider>
        <StatusContent status={status} onTranslate={jest.fn()} onClick={onClick} />
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

    expect(screen.getByRole('button', { name: 'View posts with #test' })).toHaveAttribute('href', '/timelines/tag/test');
    expect(Overlay.lastTarget).toBe(inline);

    click(badge);

    expect(screen.getByRole('button', { name: 'View posts with #mastodon' })).toHaveAttribute('href', '/timelines/tag/mastodon');
    expect(screen.getByRole('button', { name: 'View alice\'s posts with #mastodon' })).toHaveAttribute('href', '/accounts/a1/posts/mastodon');
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
    const badge = screen.getByRole('link', { name: '#Test' });

    expect(translated.textContent).toBe('#different');

    click(badge);
    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtag' }));
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith('#Test');

    click(translated);
    fireEvent.click(screen.getByRole('button', { name: 'Copy hashtags' }));
    expect(navigator.clipboard.writeText).toHaveBeenLastCalledWith('#test #mastodon #fedibird');
    expect(navigator.clipboard.writeText).not.toHaveBeenCalledWith(expect.stringContaining('#different'));
  });

  it('uses the acct when the account has no username', () => {
    const account = { id: 'a1', display_name: 'Alice', username: '', acct: 'alice@example.com' };
    const { container } = renderMenu({
      account,
      status: buildStatus({ account }),
    });

    click(container.querySelector('a.status__content__hashtag-badge'));

    expect(screen.getByRole('button', { name: 'View alice@example.com\'s posts with #mastodon' })).toHaveAttribute('href', '/accounts/a1/posts/mastodon');
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

  it('opens filters in a new tab and hides favourite and mute when signed out', () => {
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

    expect(mute).toHaveAttribute('href', '/filters');
    expect(mute).toHaveAttribute('target', '_blank');
    expect(mute.closest('li').className).toContain('dropdown-menu__item--dangerous');

    fireEvent.click(mute);

    expect(window.open).toHaveBeenCalledWith('/filters', '_blank', 'noopener,noreferrer');
    expect(history.push).not.toHaveBeenCalled();
    signedIn.unmount();

    const signedOut = renderMenu({ signedIn: false });
    click(signedOut.container.querySelector('.status__content__text a.mention.hashtag'));

    expect(screen.getByRole('button', { name: 'View posts with #test' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Copy hashtag' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Copy hashtags' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Add to favorites' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Mute #test' })).toBeNull();
  });
});
