/* eslint-disable react/prop-types, react/jsx-no-bind */

import { fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/actions/announcements', () => ({
  fetchAnnouncements: () => ({ type: 'ANNOUNCEMENTS_FETCH_REQUEST' }),
  toggleShowAnnouncements: () => ({ type: 'ANNOUNCEMENTS_TOGGLE_SHOW' }),
}));

jest.mock('mastodon/features/getting_started/containers/announcements_container', () => () => null);

jest.mock('mastodon/api', () => {
  const get = jest.fn(() => new Promise(() => {}));
  const put = jest.fn(() => Promise.resolve({ data: {} }));
  const api = jest.fn(() => ({ get, put }));

  return {
    __esModule: true,
    default: api,
    getLinks: () => ({ refs: [] }),
  };
});

jest.mock('../../ui/containers/status_list_container', () => {
  const React = require('react');

  return function StatusListContainer (props) {
    let pane = 'single';

    if (props.includePendingItems) {
      pane = 'live';
    } else if (props.dataTimelineId && props.dataTimelineId !== 'home') {
      pane = 'history';
    }

    return (
      <div
        className='scrollable'
        data-pane={pane}
        data-timeline={props.dataTimelineId || props.timelineId}
        data-context={props.timelineId}
        data-bind={props.bindToDocument ? 'document' : 'column'}
        data-track-scroll={props.trackScroll === false ? 'false' : 'true'}
        data-track-intersection={props.trackIntersection === false ? 'false' : 'true'}
        data-manage-scroll={props.manageTimelineScrollState === false ? 'false' : 'true'}
      >
        {props.onLoadMore && <button type='button' data-testid={`load-${pane}`} onClick={() => props.onLoadMore('70')}>Load more</button>}
      </div>
    );
  };
});

import HomeTimeline from '../index';
import settings from 'mastodon/reducers/settings';
import timelines from 'mastodon/reducers/timelines';

const announcements = (state = ImmutableMap({ items: ImmutableList(), show: false })) => state;

const buildStore = () => {
  const reducer = combineReducers({
    timelines,
    settings,
    announcements,
  });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state
    .setIn(['settings', 'columns'], ImmutableList())
    .setIn(['timelines', 'home'], ImmutableMap({
      unread: 0,
      online: true,
      top: false,
      isLoading: false,
      hasMore: true,
      isPartial: false,
      pendingItems: ImmutableList(['120']),
      items: ImmutableList(['100', '90', '80']),
    }));

  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderHome = (store, props) => render(
  <Provider store={store}>
    <HomeTimeline {...props} />
  </Provider>,
);

describe('HomeTimeline split', () => {
  beforeEach(() => {
    const portal = document.createElement('div');
    portal.id = 'tabs-bar__portal';
    document.body.appendChild(portal);

  });

  afterEach(() => {
    const portal = document.getElementById('tabs-bar__portal');

    if (portal) {
      portal.remove();
    }
  });

  it('does not offer split in single column and keeps document scrolling', () => {
    const store = buildStore();
    const { container } = renderHome(store, { multiColumn: false });

    expect(screen.queryByRole('button', { name: 'Split timeline' })).toBeNull();
    expect(container.querySelector('.scrollable').getAttribute('data-bind')).toBe('document');
    expect(container.querySelector('.timeline-split')).toBeNull();
  });

  it('splits and unsplits from the header while keeping the captured scroll offset', () => {
    const store = buildStore();
    const { container } = renderHome(store, { columnId: 'col-a', multiColumn: true });
    const before = container.querySelector('.scrollable');

    before.scrollTop = 320;
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const history = container.querySelector('.timeline-split__pane--history .scrollable');
    const live = container.querySelector('.timeline-split__pane--live .scrollable');

    expect(store.getState().getIn(['timelines', 'home', 'splitTimelineId'])).toBe('home:split:col-a');
    expect(store.getState().getIn(['timelines', 'home', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(store.getState().getIn(['timelines', 'home:split:col-a', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(history.scrollTop).toBe(320);
    expect(live.getAttribute('data-track-intersection')).toBe('false');
    expect(live.getAttribute('data-manage-scroll')).toBe('false');
    expect(live.getAttribute('data-track-scroll')).toBe('false');
    expect(live.getAttribute('data-context')).toBe('home');
    expect(container.querySelector('[data-testid="load-live"]')).toBeNull();
    expect(container.querySelector('[data-testid="load-history"]')).not.toBeNull();

    fireEvent.click(container.querySelector('[data-testid="load-history"]'));

    expect(store.getState().getIn(['timelines', 'home:split:col-a', 'isLoading'])).toBe(true);
    expect(store.getState().getIn(['timelines', 'home', 'isLoading'])).not.toBe(true);

    history.scrollTop = 480;
    fireEvent.click(container.querySelector('.column-header__split-button'));

    const restored = container.querySelector('.scrollable');

    expect(container.querySelector('.timeline-split')).toBeNull();
    expect(restored.scrollTop).toBe(480);
    expect(store.getState().get('timelines').has('home:split:col-a')).toBe(false);
    expect(store.getState().getIn(['timelines', 'home', 'splitTimelineId'])).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'home', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(store.getState().getIn(['timelines', 'home', 'pendingItems']).includes('120')).toBe(true);
  });

  it('scrolls the live pane when the header title is clicked', () => {
    const store = buildStore();
    const { container } = renderHome(store, { columnId: 'col-a', multiColumn: true });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const scrollables = container.querySelectorAll('.scrollable');
    scrollables.forEach(node => {
      node.scrollTo = jest.fn();
    });

    fireEvent.click(screen.getByRole('button', { name: 'Home' }));

    expect(scrollables[0].getAttribute('data-pane')).toBe('live');
    expect(scrollables[0].scrollTo).toHaveBeenCalledWith({ behavior: 'smooth', top: 0 });
    expect(scrollables[1].scrollTo).not.toHaveBeenCalled();
  });

  it('unsplits from the splitter and commits keyboard ratio changes only on commit', () => {
    const store = buildStore();
    const { container } = renderHome(store, { columnId: 'col-a', multiColumn: true });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const separator = container.querySelector('[role="separator"]');

    expect(separator).toHaveAttribute('aria-orientation', 'horizontal');
    expect(separator).toHaveAttribute('aria-valuemin', '20');
    expect(separator).toHaveAttribute('aria-valuemax', '80');
    expect(separator).toHaveAttribute('aria-valuenow', '35');
    expect(separator).toHaveAttribute('aria-label', 'Timeline splitter');

    fireEvent.keyDown(separator, { key: 'ArrowDown' });
    expect(separator.getAttribute('aria-valuenow')).toBe('40');
    expect(store.getState().getIn(['settings', 'home', 'splitRatio'])).toBe(40);

    fireEvent.keyDown(separator, { key: 'ArrowUp', shiftKey: true });
    expect(store.getState().getIn(['settings', 'home', 'splitRatio'])).toBe(30);

    const originalRect = HTMLElement.prototype.getBoundingClientRect;
    HTMLElement.prototype.getBoundingClientRect = () => ({ top: 100, height: 400, left: 0, width: 300, bottom: 500, right: 300, x: 0, y: 100, toJSON () {} });

    const emitPointer = (type, target, clientY) => {
      const event = new Event(type, { bubbles: true, cancelable: true });
      Object.defineProperties(event, {
        clientY: { value: clientY },
        button: { value: 0 },
        pointerId: { value: 1 },
      });
      target.dispatchEvent(event);
    };

    emitPointer('pointerdown', separator, 180);
    emitPointer('pointermove', document, 300);
    expect(store.getState().getIn(['settings', 'home', 'splitRatio'])).toBe(30);

    emitPointer('pointerup', document, 300);
    HTMLElement.prototype.getBoundingClientRect = originalRect;
    expect(store.getState().getIn(['settings', 'home', 'splitRatio'])).toBe(50);

    fireEvent.click(container.querySelector('.timeline-split__close'));
    expect(container.querySelector('.timeline-split')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    expect(container.querySelector('[role="separator"]').getAttribute('aria-valuenow')).toBe('50');
  });

  it('disables split on other Home columns and while the timeline is partial', () => {
    const store = buildStore();
    const { container } = render(
      <Provider store={store}>
        <HomeTimeline columnId='col-a' multiColumn />
        <HomeTimeline columnId='col-b' multiColumn />
      </Provider>,
    );

    let buttons = container.querySelectorAll('.column-header__split-button');
    fireEvent.click(buttons[0]);

    buttons = container.querySelectorAll('.column-header__split-button');
    expect(buttons[0]).toHaveAttribute('aria-pressed', 'true');
    expect(buttons[1]).toBeDisabled();
    expect(buttons[1]).toHaveAttribute('aria-label', 'Another Home timeline is already split');

    fireEvent.click(buttons[0]);
    buttons = container.querySelectorAll('.column-header__split-button');
    expect(buttons[1]).not.toBeDisabled();
  });

  it('disables a new split while home is regenerating', () => {
    const store = buildStore();
    store.dispatch({ type: 'TIMELINE_MARK_AS_PARTIAL', timeline: 'home' });

    const { container } = renderHome(store, { columnId: 'col-a', multiColumn: true });
    const button = container.querySelector('.column-header__split-button');

    expect(button).toBeDisabled();
    fireEvent.click(button);
    expect(store.getState().getIn(['timelines', 'home', 'splitTimelineId'])).toBeUndefined();
  });

  it('restores canonical home when the split owner unmounts', () => {
    const store = buildStore();
    const { unmount } = renderHome(store, { columnId: 'col-a', multiColumn: true });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    expect(store.getState().hasIn(['timelines', 'home:split:col-a'])).toBe(true);

    unmount();

    expect(store.getState().hasIn(['timelines', 'home:split:col-a'])).toBe(false);
    expect(store.getState().getIn(['timelines', 'home', 'splitTimelineId'])).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'home', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(store.getState().getIn(['timelines', 'home', 'pendingItems'])).toEqual(ImmutableList(['120']));
    expect(store.getState().getIn(['timelines', 'home', 'online'])).toBe(true);
  });
});
