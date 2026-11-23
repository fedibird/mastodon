import { render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { IntlProvider } from 'react-intl';
import { Provider } from 'react-redux';
import { MemoryRouter } from 'react-router-dom';
import { createStore } from 'redux';
import fs from 'fs';
import path from 'path';

jest.mock('mastodon/features/compose/containers/compose_form_container', () => () => <div data-testid='compose-form' />);
jest.mock('mastodon/features/compose/containers/navigation_container', () => () => <div data-testid='navigation' />);
jest.mock('mastodon/features/compose/containers/search_container', () => () => <div data-testid='search' />);
jest.mock('mastodon/features/compose/containers/search_results_container', () => () => <div data-testid='search-results' />);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('../containers/compose_form_container', () => () => <div data-testid='compose-form' />);
jest.mock('../containers/navigation_container', () => () => <div data-testid='navigation' />);
jest.mock('../containers/search_container', () => () => <div data-testid='search' />);
jest.mock('../containers/search_results_container', () => () => <div data-testid='search-results' />);
jest.mock('mastodon/features/ui/components/notifications_counter_icon', () => () => null);
jest.mock('../../../../images/elephant_ui_plane.svg', () => 'plane.svg');
jest.mock('mastodon/initial_state', () => ({
  mascot: null,
  show_tab_bar_label: false,
  enableLimitedTimeline: false,
  enableFederatedTimeline: false,
  enableLocalTimeline: false,
}));

import { EmojiMuteNoticeContext } from 'mastodon/components/emoji_mute_load_notice';
import Compose from '../index';

const notice = {
  boot: 'error',
  failure: 'unavailable',
  onRetry: jest.fn(),
  onIgnore: jest.fn(),
  onDisable: jest.fn(),
  onReload: jest.fn(),
};

const storeFor = columns => createStore(() => fromJS({
  settings: { columns },
  search: { submitted: false, hidden: true },
}));

const draw = columns => render(
  <Provider store={storeFor(columns)}>
    <IntlProvider locale='en'>
      <MemoryRouter>
        <EmojiMuteNoticeContext.Provider value={notice}>
          <div data-testid='pinned'>
            <Compose columnId='compose-column' multiColumn />
          </div>
          <div data-testid='route'>
            <Compose multiColumn />
          </div>
        </EmojiMuteNoticeContext.Provider>
      </MemoryRouter>
    </IntlProvider>
  </Provider>,
);

describe('advanced compose emoji mute notice', () => {
  it('shows one notice on the pinned drawer when that column exists, and on the route drawer when it does not', () => {
    const pinned = draw(fromJS([{ id: 'COMPOSE', uuid: 'compose-column' }, { id: 'HOME', uuid: 'home' }]));
    const pinnedNotices = pinned.container.querySelectorAll('.emoji-mute-load-notice');
    const pinnedDrawer = pinned.getByTestId('pinned').querySelector('.drawer');
    const routeDrawer = pinned.getByTestId('route').querySelector('.drawer');

    expect(pinnedNotices).toHaveLength(1);
    expect(pinned.getByTestId('pinned').querySelector('.emoji-mute-load-notice')).not.toBeNull();
    expect(pinned.getByTestId('route').querySelector('.emoji-mute-load-notice')).toBeNull();
    expect(pinnedDrawer.className).toContain('drawer--emoji-mute-notice');
    expect(routeDrawer.className).not.toContain('drawer--emoji-mute-notice');
    expect(pinnedDrawer.querySelector('[data-testid="search"]')).not.toBeNull();
    expect(pinnedDrawer.querySelector('[data-testid="compose-form"]')).not.toBeNull();
    pinned.unmount();

    const routeOnly = render(
      <Provider store={storeFor(fromJS([{ id: 'HOME', uuid: 'home' }]))}>
        <IntlProvider locale='en'>
          <MemoryRouter>
            <EmojiMuteNoticeContext.Provider value={notice}>
              <Compose multiColumn />
            </EmojiMuteNoticeContext.Provider>
          </MemoryRouter>
        </IntlProvider>
      </Provider>,
    );

    expect(routeOnly.container.querySelectorAll('.emoji-mute-load-notice')).toHaveLength(1);
    expect(routeOnly.container.querySelector('.drawer').className).toContain('drawer--emoji-mute-notice');
    expect(routeOnly.getByTestId('search')).not.toBeNull();
    expect(routeOnly.getByTestId('compose-form')).not.toBeNull();
    routeOnly.unmount();

    const stylesheet = fs.readFileSync(path.join(__dirname, '../../../../styles/mastodon/emoji_mute_load_notice.scss'), 'utf8');

    expect(stylesheet).toContain('.drawer.drawer--emoji-mute-notice');
    expect(stylesheet).not.toContain('.drawer:has(> .emoji-mute-load-notice)');
    expect(stylesheet).toContain('.emoji-mute-load-notice__close');
    expect(stylesheet).toContain('min-width: 44px');
    expect(stylesheet).toContain('min-height: 44px');
  });

  it('drops the compose spacing when the ignored notice is closed', () => {
    const closed = render(
      <Provider store={storeFor(fromJS([{ id: 'HOME', uuid: 'home' }]))}>
        <IntlProvider locale='en'>
          <MemoryRouter>
            <EmojiMuteNoticeContext.Provider value={{ ...notice, boot: 'ignored', ignoredNoticeClosed: true }}>
              <Compose multiColumn />
            </EmojiMuteNoticeContext.Provider>
          </MemoryRouter>
        </IntlProvider>
      </Provider>,
    );
    const drawer = closed.container.querySelector('.drawer');

    expect(closed.container.querySelector('.emoji-mute-load-notice')).toBeNull();
    expect(drawer.className).not.toContain('drawer--emoji-mute-notice');
    expect(drawer.querySelector('[data-testid="search"]')).not.toBeNull();
    expect(drawer.querySelector('[data-testid="compose-form"]')).not.toBeNull();
    closed.unmount();

    const open = render(
      <Provider store={storeFor(fromJS([{ id: 'HOME', uuid: 'home' }]))}>
        <IntlProvider locale='en'>
          <MemoryRouter>
            <EmojiMuteNoticeContext.Provider value={{ ...notice, boot: 'ignored', ignoredNoticeClosed: false, onDismissIgnored: jest.fn() }}>
              <Compose multiColumn />
            </EmojiMuteNoticeContext.Provider>
          </MemoryRouter>
        </IntlProvider>
      </Provider>,
    );

    expect(open.container.querySelectorAll('.emoji-mute-load-notice')).toHaveLength(1);
    expect(open.container.querySelector('.drawer').className).toContain('drawer--emoji-mute-notice');
    expect(open.container.querySelector('.emoji-mute-load-notice__close')).not.toBeNull();
    open.unmount();
  });
});
