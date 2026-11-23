/* eslint-disable react/prop-types */

import { fireEvent, render } from '@testing-library/react';
import fs from 'fs';
import { fromJS, List as ImmutableList } from 'immutable';
import path from 'path';
import PropTypes from 'prop-types';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  mascot: null,
  show_tab_bar_label: false,
  enableLimitedTimeline: false,
  enableFederatedTimeline: false,
  enableLocalTimeline: false,
  enablePersonalTimeline: false,
  place_tab_bar_at_bottom: false,
  disableSwiping: true,
  show_navigation_panel: false,
  autoPlayEmoji: false,
  me: '1',
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
    locale: 'en',
  };

  return {
    injectIntl: Component => {
      const Wrapped = props => <Component {...props} intl={intl} />;
      return Wrapped;
    },
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => <span>{defaultMessage}</span>,
  };
});

jest.mock('react-router-dom', () => ({
  Link: ({ children, to }) => <a href={to}>{children}</a>,
  NavLink: ({ children, to }) => <a href={to}>{children}</a>,
}));

jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/features/ui/components/notifications_counter_icon', () => () => null);
jest.mock('mastodon/utils/log_out', () => ({ logOut: jest.fn() }));
jest.mock('../../../images/elephant_ui_plane.svg', () => 'elephant.svg');
jest.mock('mastodon/features/compose/containers/search_container', () => () => <div data-testid='search' />);
jest.mock('mastodon/features/compose/containers/compose_form_container', () => () => <div data-testid='composer' />);
jest.mock('mastodon/features/compose/containers/navigation_container', () => () => <div data-testid='account-nav' />);
jest.mock('mastodon/features/compose/containers/search_results_container', () => () => <div data-testid='search-results' />);
jest.mock('mastodon/features/ui/util/optional_motion', () => ({ children }) => (typeof children === 'function' ? children({ x: -100 }) : children));
jest.mock('mastodon/features/ui/components/tabs_bar', () => {
  const React = require('react');

  return {
    __esModule: true,
    default: () => <div data-testid='tabs' />,
    getSwipeableIndex: () => -1,
    getSwipeableLink: () => '/timelines/home',
  };
});
jest.mock('mastodon/features/ui/components/navigation_panel', () => () => <div data-testid='navigation-panel' />);
jest.mock('mastodon/features/ui/containers/bundle_container', () => {
  const React = require('react');

  return function BundleContainer({ children, fetchComponent, loading: Loading, error: ErrorComponent }) {
    const harness = global.__emojiMuteBundleHarness || { mode: 'column' };
    const composeColumn = fetchComponent && fetchComponent.name === 'Compose';

    if (composeColumn && harness.mode === 'loading') {
      return Loading ? <Loading /> : <div data-testid='bundle-loading' />;
    }

    if (composeColumn && harness.mode === 'error') {
      return ErrorComponent
        ? <ErrorComponent onRetry={harness.onRetry || (() => {})} />
        : <div data-testid='bundle-error' />;
    }

    if (composeColumn && harness.mode === 'compose') {
      const ComposeColumn = require('mastodon/features/compose').default;
      return children(ComposeColumn);
    }

    const Column = () => <div data-testid='bundled-column' />;
    return children(Column);
  };
});

import EmojiMuteLoadNotice, { emojiMuteNoticeVisible, EmojiMuteNoticeContext, resetEmojiMuteNoticeOwnersForTests } from '../emoji_mute_load_notice';
import ComposePanel from '../../features/ui/components/compose_panel';
import ColumnsArea from '../../features/ui/components/columns_area';
import Compose from '../../features/compose';

const store = createStore(() => fromJS({
  settings: { columns: [] },
  search: { submitted: false, hidden: true },
  compose: { references: [], context_references: [] },
  lists: {},
}));

const notice = boot => ({
  boot,
  failure: boot === 'error' ? 'unavailable' : null,
  preferenceSaving: false,
  preferenceError: false,
  onRetry: jest.fn(),
  onIgnore: jest.fn(),
  onDisable: jest.fn(),
  onReload: jest.fn(),
});

class RouterProvider extends React.Component {

  static propTypes = {
    children: PropTypes.node,
    pathname: PropTypes.string,
  };

  static defaultProps = {
    pathname: '/timelines/home',
  };

  static childContextTypes = {
    router: PropTypes.object.isRequired,
  };

  getChildContext () {
    return {
      router: {
        history: {
          location: { pathname: this.props.pathname },
          push () {},
          listen () {
            return () => {};
          },
        },
      },
    };
  }

  render () {
    return this.props.children;
  }

}

const setViewport = matches => {
  window.matchMedia = jest.fn().mockImplementation(query => ({
    matches,
    media: query,
    addEventListener: jest.fn(),
    removeEventListener: jest.fn(),
    addListener: jest.fn(),
    removeListener: jest.fn(),
  }));
};

const noticeTree = (ui, boot = 'error', pathname = '/timelines/home') => (
  <Provider store={store}>
    <EmojiMuteNoticeContext.Provider value={notice(boot)}>
      <RouterProvider pathname={pathname}>{ui}</RouterProvider>
    </EmojiMuteNoticeContext.Provider>
  </Provider>
);

const renderNotice = (ui, boot = 'error', pathname = '/timelines/home') => render(noticeTree(ui, boot, pathname));

describe('emoji mute load notice placement', () => {
  beforeEach(() => {
    setViewport(false);
    global.__emojiMuteBundleHarness = { mode: 'column' };
    resetEmojiMuteNoticeOwnersForTests();
  });

  afterEach(() => {
    delete global.__emojiMuteBundleHarness;
    resetEmojiMuteNoticeOwnersForTests();
  });

  it('puts one card before search in the wide single-column compose panel', () => {
    const { container } = renderNotice(<ComposePanel />);
    const panel = container.querySelector('.compose-panel');
    const children = Array.from(panel.children);

    expect(children[0].classList.contains('emoji-mute-load-notice')).toBe(true);
    expect(children[0].getAttribute('data-placement')).toBe('compose-panel');
    expect(children[1].getAttribute('data-testid')).toBe('search');
    expect(container.querySelectorAll('.emoji-mute-load-notice')).toHaveLength(1);
    expect(container.querySelector('.emoji-mute-load-notice').getAttribute('role')).toBe('status');
    expect(container.querySelector('.emoji-mute-load-notice').getAttribute('aria-live')).toBe('polite');
    expect(container.querySelector('.emoji-mute-load-notice__title').textContent).toContain('Couldn\'t load emoji mutes');
  });

  it('leaves no empty card in the compose panel when loading succeeded', () => {
    const { container } = renderNotice(<ComposePanel />, 'ready');
    const panel = container.querySelector('.compose-panel');

    expect(panel.querySelector('.emoji-mute-load-notice')).toBeNull();
    expect(panel.children[0].getAttribute('data-testid')).toBe('search');
  });

  it('puts one card under the multi-column drawer navigation and above search', () => {
    const { container } = renderNotice(
      <Compose multiColumn columns={ImmutableList()} intl={{ formatMessage: ({ defaultMessage }) => defaultMessage }} />,
    );
    const drawer = container.querySelector('.drawer');
    const children = Array.from(drawer.children);

    expect(children[0].classList.contains('drawer__header')).toBe(true);
    expect(children[1].classList.contains('emoji-mute-load-notice')).toBe(true);
    expect(children[1].getAttribute('data-placement')).toBe('drawer');
    expect(children[2].getAttribute('data-testid')).toBe('search');
    expect(container.querySelectorAll('.emoji-mute-load-notice')).toHaveLength(1);
  });

  it('does not put the drawer card on the single-column compose route', () => {
    const { container } = renderNotice(<Compose multiColumn={false} />);

    expect(container.querySelector('.emoji-mute-load-notice')).toBeNull();
  });

  it('puts one card under the tabs and above the column on a narrow single column', () => {
    setViewport(true);
    const { container } = renderNotice(
      <ColumnsArea singleColumn columns={ImmutableList()} isModalOpen={false} dispatch={jest.fn()} links={[]}>
        <div data-testid='column-child'>home</div>
      </ColumnsArea>,
    );
    const main = container.querySelector('.columns-area__panels__main');
    const children = Array.from(main.children);

    expect(container.querySelector('.compose-panel')).toBeNull();
    expect(children[0].getAttribute('data-testid')).toBe('tabs');
    expect(children[1].classList.contains('emoji-mute-load-notice')).toBe(true);
    expect(children[1].getAttribute('data-placement')).toBe('columns');
    expect(children[2].querySelector('[data-testid="column-child"]')).not.toBeNull();
    expect(children[1].compareDocumentPosition(children[2]) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(container.querySelectorAll('.emoji-mute-load-notice')).toHaveLength(1);
  });

  it('keeps the wide single-column card in the compose panel only', () => {
    setViewport(false);
    const { container } = renderNotice(
      <ColumnsArea singleColumn columns={ImmutableList()} isModalOpen={false} dispatch={jest.fn()} links={[]}>
        <div data-testid='column-child'>home</div>
      </ColumnsArea>,
    );
    const notices = container.querySelectorAll('.emoji-mute-load-notice');

    expect(notices).toHaveLength(1);
    expect(notices[0].getAttribute('data-placement')).toBe('compose-panel');
    expect(container.querySelector('.columns-area__panels__main .emoji-mute-load-notice')).toBeNull();
    expect(container.querySelector('.compose-panel .emoji-mute-load-notice')).not.toBeNull();
  });

  it('pins the multi-column fallback over the viewport instead of adding a scrolled column', () => {
    const ColumnChild = () => <div data-testid='column-child'>home</div>;
    const { container } = renderNotice(
      <ColumnsArea singleColumn={false} columns={ImmutableList()} isModalOpen={false} dispatch={jest.fn()} links={[]}>
        <ColumnChild />
      </ColumnsArea>,
    );
    const area = container.querySelector('.columns-area');
    const overlay = container.querySelector('.emoji-mute-load-notice-overlay');
    const card = overlay.querySelector('.emoji-mute-load-notice');

    area.scrollLeft = 480;

    expect(card).not.toBeNull();
    expect(card.getAttribute('data-placement')).toBe('overlay');
    expect(area.contains(card)).toBe(false);
    expect(area.scrollLeft).toBe(480);
    expect(container.querySelectorAll('.emoji-mute-load-notice')).toHaveLength(1);
    expect(container.querySelector('[data-testid="column-child"]')).not.toBeNull();

    const stylesheet = fs.readFileSync(path.join(__dirname, '../../../styles/mastodon/emoji_mute_load_notice.scss'), 'utf8');
    const overlayRule = stylesheet.slice(
      stylesheet.indexOf('.emoji-mute-load-notice-overlay {'),
      stylesheet.indexOf('.compose-panel > .emoji-mute-load-notice'),
    );

    expect(overlayRule.startsWith('.emoji-mute-load-notice-overlay {')).toBe(true);
    expect(overlayRule).toContain('position: fixed');
    expect(overlayRule).toContain('overflow-y: auto');
    expect(overlayRule).toContain('max-height: calc(100vh - 20px - env(safe-area-inset-top, 0px) - env(safe-area-inset-bottom, 0px))');
    expect(overlayRule).toContain('> .emoji-mute-load-notice');
    expect(stylesheet).not.toContain('.columns-area > .emoji-mute-load-notice-slot');
    expect(overlay.querySelector('.emoji-mute-load-notice__disable')).not.toBeNull();
    expect(overlay.querySelector('.emoji-mute-load-notice__action--primary')).not.toBeNull();
  });

  it('uses one visibility decision for the card, the drawer spacing, and the overlay', () => {
    const error = { boot: 'error', ignoredNoticeClosed: false };
    const ignored = { boot: 'ignored', ignoredNoticeClosed: false };
    const closed = { boot: 'ignored', ignoredNoticeClosed: true };
    const session = { boot: 'session-changed' };

    expect(emojiMuteNoticeVisible(error, 'drawer')).toBe(true);
    expect(emojiMuteNoticeVisible(error, 'overlay')).toBe(true);
    expect(emojiMuteNoticeVisible(ignored, 'drawer')).toBe(true);
    expect(emojiMuteNoticeVisible(closed, 'drawer')).toBe(false);
    expect(emojiMuteNoticeVisible(closed, 'overlay')).toBe(false);
    expect(emojiMuteNoticeVisible(session, 'drawer')).toBe(false);
    expect(emojiMuteNoticeVisible(session, 'overlay')).toBe(false);
    expect(emojiMuteNoticeVisible(session, 'session')).toBe(true);
    expect(emojiMuteNoticeVisible(null, 'drawer')).toBe(false);
  });

  it('shows the fallback while compose is loading or failed, and removes it once the drawer owns the card', () => {
    const columns = fromJS([{ id: 'COMPOSE', uuid: 'compose-column' }, { id: 'HOME', uuid: 'home' }]);
    global.__emojiMuteBundleHarness = { mode: 'loading' };
    const view = renderNotice(
      <ColumnsArea singleColumn={false} columns={columns} isModalOpen={false} dispatch={jest.fn()} links={[]} />,
    );

    expect(view.container.querySelector('.drawer__pager')).not.toBeNull();
    expect(view.container.querySelector('.drawer .emoji-mute-load-notice')).toBeNull();
    expect(view.container.querySelector('.emoji-mute-load-notice-overlay .emoji-mute-load-notice')).not.toBeNull();
    expect(view.container.querySelectorAll('.emoji-mute-load-notice')).toHaveLength(1);
    const area = view.container.querySelector('.columns-area');
    area.scrollLeft = 360;

    global.__emojiMuteBundleHarness = { mode: 'error' };
    view.rerender(noticeTree(
      <ColumnsArea singleColumn={false} columns={columns} isModalOpen={false} dispatch={jest.fn()} links={[]} />,
    ));

    expect(view.container.querySelector('.error-column')).not.toBeNull();
    expect(view.container.querySelector('.drawer .emoji-mute-load-notice')).toBeNull();
    expect(view.container.querySelector('.emoji-mute-load-notice-overlay .emoji-mute-load-notice')).not.toBeNull();
    expect(view.container.querySelector('.columns-area').scrollLeft).toBe(360);

    global.__emojiMuteBundleHarness = { mode: 'compose' };
    view.rerender(noticeTree(
      <ColumnsArea singleColumn={false} columns={columns} isModalOpen={false} dispatch={jest.fn()} links={[]} />,
    ));

    expect(view.container.querySelectorAll('.emoji-mute-load-notice')).toHaveLength(1);
    expect(view.container.querySelector('.drawer .emoji-mute-load-notice')).not.toBeNull();
    expect(view.container.querySelector('.emoji-mute-load-notice-overlay')).toBeNull();
    expect(view.container.querySelector('.columns-area').scrollLeft).toBe(360);

    global.__emojiMuteBundleHarness = { mode: 'error' };
    view.rerender(noticeTree(
      <ColumnsArea singleColumn={false} columns={columns} isModalOpen={false} dispatch={jest.fn()} links={[]} />,
    ));

    expect(view.container.querySelector('.drawer .emoji-mute-load-notice')).toBeNull();
    expect(view.container.querySelector('.emoji-mute-load-notice-overlay .emoji-mute-load-notice')).not.toBeNull();
    expect(view.container.querySelector('.columns-area').scrollLeft).toBe(360);
    view.unmount();
  });

  it('keeps one drawer card when that compose route is mounted, and the overlay when the route is not', () => {
    const RouteLoading = () => <div data-testid='route-loading'>loading</div>;
    const pending = renderNotice(
      <ColumnsArea singleColumn={false} columns={ImmutableList()} isModalOpen={false} dispatch={jest.fn()} links={[]}>
        <RouteLoading />
      </ColumnsArea>,
      'error',
      '/statuses/new',
    );

    expect(pending.container.querySelector('.emoji-mute-load-notice-overlay .emoji-mute-load-notice')).not.toBeNull();
    expect(pending.container.querySelector('.drawer .emoji-mute-load-notice')).toBeNull();
    expect(pending.container.querySelectorAll('.emoji-mute-load-notice')).toHaveLength(1);
    pending.unmount();

    const route = renderNotice(
      <ColumnsArea singleColumn={false} columns={ImmutableList()} isModalOpen={false} dispatch={jest.fn()} links={[]}>
        <Compose multiColumn />
      </ColumnsArea>,
      'error',
      '/statuses/new',
    );

    expect(route.container.querySelectorAll('.emoji-mute-load-notice')).toHaveLength(1);
    expect(route.container.querySelector('.drawer .emoji-mute-load-notice')).not.toBeNull();
    expect(route.container.querySelector('.emoji-mute-load-notice').getAttribute('data-placement')).toBe('drawer');
    expect(route.container.querySelector('.emoji-mute-load-notice-overlay')).toBeNull();
  });

  it('retries an ordinary failure and reloads a session change or a new sign-in', () => {
    const failed = notice('error');
    const failure = render(
      <EmojiMuteNoticeContext.Provider value={failed}>
        <EmojiMuteLoadNotice placement='compose-panel' />
      </EmojiMuteNoticeContext.Provider>,
    );

    expect(failure.container.querySelector('.emoji-mute-load-notice').getAttribute('role')).toBe('status');
    fireEvent.click(failure.getByText('Try again'));
    expect(failed.onRetry).toHaveBeenCalledTimes(1);
    expect(failed.onReload).not.toHaveBeenCalled();

    const changed = notice('session-changed');
    const session = render(
      <EmojiMuteNoticeContext.Provider value={changed}>
        <EmojiMuteLoadNotice placement='session' />
      </EmojiMuteNoticeContext.Provider>,
    );

    expect(session.container.querySelector('.emoji-mute-load-notice').getAttribute('role')).toBe('alert');
    expect(session.container.querySelector('.emoji-mute-load-notice').getAttribute('aria-live')).toBe('assertive');
    fireEvent.click(session.getByText('Reload the page'));
    expect(changed.onReload).toHaveBeenCalledTimes(1);
    expect(changed.onRetry).not.toHaveBeenCalled();

    const expired = { ...notice('error'), failure: 'unauthorized' };
    const signIn = render(
      <EmojiMuteNoticeContext.Provider value={expired}>
        <EmojiMuteLoadNotice placement='compose-panel' />
      </EmojiMuteNoticeContext.Provider>,
    );

    fireEvent.click(signIn.getByText('Reload and sign in'));
    expect(expired.onReload).toHaveBeenCalledTimes(1);
    expect(expired.onRetry).not.toHaveBeenCalled();
  });
});
