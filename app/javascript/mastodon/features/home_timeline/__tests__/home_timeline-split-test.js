/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
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
  const { useSelector } = require('react-redux');

  return function StatusListContainer (props) {
    const timelineId = props.dataTimelineId || props.timelineId;
    const isPartial = useSelector(state => !!state.getIn(['timelines', timelineId, 'isPartial']));
    const items = useSelector(state => state.getIn(['timelines', timelineId, 'items']));
    let pane = 'single';

    if (props.includePendingItems) {
      pane = 'live';
    } else if (props.dataTimelineId && props.dataTimelineId !== 'home') {
      pane = 'history';
    }

    if (isPartial) {
      return <div data-regenerating='true' data-pane={pane} data-timeline={timelineId} />;
    }

    const ids = items && items.toArray ? items.toArray().filter(id => id !== null) : [];

    return (
      <div
        className='scrollable'
        data-pane={pane}
        data-timeline={timelineId}
        data-context={props.timelineId}
        data-bind={props.bindToDocument ? 'document' : 'column'}
        data-track-scroll={props.trackScroll === false ? 'false' : 'true'}
        data-track-intersection={props.trackIntersection === false ? 'false' : 'true'}
        data-manage-scroll={props.manageTimelineScrollState === false ? 'false' : 'true'}
      >
        {ids.map(id => <article key={id} data-id={id} />)}
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

const activeSplitId = (store) => store.getState().getIn(['timelines', 'home', 'splitTimelineId']);

const expectSplitId = (store, columnId) => {
  const id = activeSplitId(store);

  expect(id).toEqual(expect.stringMatching(new RegExp(`^home:split:${columnId}:.+`)));

  return id;
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
    document.querySelectorAll('.tabs-bar__wrapper').forEach(node => node.remove());
    document.body.classList.remove('status-timeline-split');

    const portal = document.getElementById('tabs-bar__portal');

    if (portal) {
      portal.remove();
    }
  });

  const box = (top, bottom) => ({
    top,
    bottom,
    left: 0,
    width: 320,
    height: Math.max(0, bottom - top),
    right: 320,
    x: 0,
    y: top,
    toJSON () {},
  });

  const scroller = () => document.scrollingElement || document.body;

  const mountTabsWrapper = (top, bottom) => {
    const portal = document.getElementById('tabs-bar__portal');
    const wrapper = document.createElement('div');
    wrapper.className = 'tabs-bar__wrapper';
    wrapper.getBoundingClientRect = () => box(top, bottom);
    portal.parentNode.insertBefore(wrapper, portal);
    wrapper.appendChild(portal);
    return wrapper;
  };

  const installRects = (resolver) => {
    const original = HTMLElement.prototype.getBoundingClientRect;

    HTMLElement.prototype.getBoundingClientRect = function () {
      return resolver(this) || box(0, 0);
    };

    return () => {
      HTMLElement.prototype.getBoundingClientRect = original;
    };
  };

  it('offers split in single column and switches both panes off document scrolling', () => {
    const store = buildStore();
    const { container } = renderHome(store, { multiColumn: false });
    const before = container.querySelector('.scrollable');

    expect(screen.getByRole('button', { name: 'Split timeline' })).toBeEnabled();
    expect(before.getAttribute('data-bind')).toBe('document');
    expect(before.getAttribute('data-track-scroll')).toBe('true');
    expect(container.querySelector('.timeline-split')).toBeNull();

    scroller().scrollTop = 900;
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const history = container.querySelector('.timeline-split__pane--history .scrollable');
    const live = container.querySelector('.timeline-split__pane--live .scrollable');

    expect(container.querySelector('.timeline-split')).not.toBeNull();
    expect(live.getAttribute('data-bind')).toBe('column');
    expect(history.getAttribute('data-bind')).toBe('column');
    expect(live.getAttribute('data-track-scroll')).toBe('false');
    expect(history.getAttribute('data-track-scroll')).toBe('false');
    expect(live.getAttribute('data-track-intersection')).toBe('false');
    expect(live.getAttribute('data-manage-scroll')).toBe('false');
    expect(container.querySelector('[data-testid="load-live"]')).toBeNull();
    expect(container.querySelector('[data-testid="load-history"]')).not.toBeNull();
    expect(scroller().scrollTop).toBe(0);
    expect(document.body.classList.contains('status-timeline-split')).toBe(true);
  });

  it('keeps the live pane scroll when the header split button closes the split', () => {
    const store = buildStore();
    const { container } = renderHome(store, { columnId: 'col-a', multiColumn: true });
    const before = container.querySelector('.scrollable');

    before.scrollTop = 320;
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const history = container.querySelector('.timeline-split__pane--history .scrollable');
    const live = container.querySelector('.timeline-split__pane--live .scrollable');

    const splitTimelineId = expectSplitId(store, 'col-a');
    expect(store.getState().getIn(['timelines', 'home', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(store.getState().getIn(['timelines', splitTimelineId, 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(history.scrollTop).toBe(320);
    expect(live.getAttribute('data-track-intersection')).toBe('false');
    expect(live.getAttribute('data-manage-scroll')).toBe('false');
    expect(live.getAttribute('data-track-scroll')).toBe('false');
    expect(live.getAttribute('data-context')).toBe('home');
    expect(container.querySelector('[data-testid="load-live"]')).toBeNull();
    expect(container.querySelector('[data-testid="load-history"]')).not.toBeNull();

    fireEvent.click(container.querySelector('[data-testid="load-history"]'));

    expect(store.getState().getIn(['timelines', splitTimelineId, 'isLoading'])).toBe(true);
    expect(store.getState().getIn(['timelines', 'home', 'isLoading'])).not.toBe(true);

    history.scrollTop = 1600;
    live.scrollTop = 320;
    fireEvent.click(container.querySelector('.column-header__split-button'));

    const restored = container.querySelector('.scrollable');

    expect(container.querySelector('.timeline-split')).toBeNull();
    expect(restored.scrollTop).toBe(320);
    expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
    expect(store.getState().getIn(['timelines', 'home', 'splitTimelineId'])).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'home', 'items'])).toEqual(ImmutableList(['120', '100', '90', '80']));
    expect(store.getState().getIn(['timelines', 'home', 'pendingItems'])).toEqual(ImmutableList());
    expect(store.getState().getIn(['timelines', 'home', 'unread'])).toBe(0);
    expect(store.getState().getIn(['timelines', 'home', 'top'])).toBe(false);
    expect(store.getState().getIn(['settings', 'home', 'splitRatio'])).toBe(35);
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
    const firstSplitId = expectSplitId(store, 'col-a');

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
    const secondSplitId = expectSplitId(store, 'col-a');
    expect(secondSplitId).not.toBe(firstSplitId);
    expect(store.getState().hasIn(['timelines', firstSplitId])).toBe(false);
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

  it('does not restore history scroll after unsplitting a partial home', () => {
    const store = buildStore();
    const { container } = renderHome(store, { columnId: 'col-a', multiColumn: true });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = expectSplitId(store, 'col-a');

    act(() => {
      store.dispatch({ type: 'TIMELINE_MARK_AS_PARTIAL', timeline: 'home' });
    });

    const history = container.querySelector('.timeline-split__pane--history .scrollable');

    expect(container.querySelector('.timeline-split__pane--live .scrollable')).toBeNull();
    expect(history).not.toBeNull();
    history.scrollTop = 640;

    fireEvent.click(container.querySelector('.column-header__split-button'));

    expect(container.querySelector('.timeline-split')).toBeNull();
    expect(container.querySelector('.scrollable')).toBeNull();
    expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
    expect(store.getState().getIn(['timelines', 'home', 'isPartial'])).toBe(true);

    act(() => {
      store.dispatch({
        type: 'TIMELINE_EXPAND_SUCCESS',
        timeline: 'home',
        statuses: [{ id: '200' }],
        next: '199',
        partial: false,
        isLoadingRecent: false,
        usePendingItems: false,
      });
    });

    expect(container.querySelector('.scrollable').scrollTop).toBe(0);
    expect(store.getState().getIn(['timelines', 'home', 'isPartial'])).toBe(false);
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
    const splitTimelineId = expectSplitId(store, 'col-a');
    expect(store.getState().hasIn(['timelines', splitTimelineId])).toBe(true);

    unmount();

    expect(store.getState().hasIn(['timelines', splitTimelineId])).toBe(false);
    expect(store.getState().getIn(['timelines', 'home', 'splitTimelineId'])).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'home', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(store.getState().getIn(['timelines', 'home', 'pendingItems'])).toEqual(ImmutableList(['120']));
    expect(store.getState().getIn(['timelines', 'home', 'online'])).toBe(true);
    expect(store.getState().getIn(['timelines', 'home', 'splitReturnAnchor'])).toBeUndefined();
  });

  it('keeps multi-column history scroll tracking when the column is not pinned', () => {
    const store = buildStore();
    const { container } = renderHome(store, { multiColumn: true });

    container.querySelector('.scrollable').scrollTop = 210;
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const history = container.querySelector('.timeline-split__pane--history .scrollable');
    const live = container.querySelector('.timeline-split__pane--live .scrollable');

    expect(history.scrollTop).toBe(210);
    expect(history.getAttribute('data-bind')).toBe('column');
    expect(history.getAttribute('data-track-scroll')).toBe('true');
    expect(live.getAttribute('data-track-scroll')).toBe('false');
    expect(document.body.classList.contains('status-timeline-split')).toBe(false);
  });

  it('restores the visible status into the history pane instead of copying document scroll', () => {
    const store = buildStore();
    mountTabsWrapper(0, 64);
    const restoreRects = installRects(element => {
      if (element.classList.contains('tabs-bar__wrapper')) {
        return box(0, 64);
      }

      if (element.classList.contains('scrollable')) {
        return element.getAttribute('data-pane') === 'history' ? box(120, 640) : box(-400, 1600);
      }

      if (element.tagName === 'ARTICLE') {
        const id = element.getAttribute('data-id');
        const pane = element.parentElement.getAttribute('data-pane');

        if (pane === 'history' && id === '90') {
          return box(520, 640);
        }

        if (id === '100') {
          return box(0, 40);
        }

        if (id === '90') {
          return box(80, 180);
        }

        return box(200, 320);
      }

      return box(0, 0);
    });
    const { container } = renderHome(store, { multiColumn: false });

    scroller().scrollTop = 900;
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    restoreRects();

    const history = container.querySelector('.timeline-split__pane--history .scrollable');

    expect(history.scrollTop).toBe(384);
    expect(scroller().scrollTop).toBe(0);
    expect(history.scrollTop).not.toBe(900);
  });

  it('uses the list offset when no status is visible at the document top', () => {
    const store = buildStore();
    mountTabsWrapper(0, 64);
    const restoreRects = installRects(element => {
      if (element.classList.contains('tabs-bar__wrapper')) {
        return box(0, 64);
      }

      if (element.classList.contains('scrollable')) {
        return element.getAttribute('data-pane') === 'single' ? box(-200, 900) : box(80, 500);
      }

      if (element.tagName === 'ARTICLE') {
        return box(-80, 20);
      }

      return box(0, 0);
    });
    const { container } = renderHome(store, { multiColumn: false });

    scroller().scrollTop = 800;
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    restoreRects();

    expect(container.querySelector('.timeline-split__pane--history .scrollable').scrollTop).toBe(264);
    expect(scroller().scrollTop).toBe(0);
  });

  it('restores the history status into the document view on unsplit', () => {
    const store = buildStore();
    mountTabsWrapper(0, 64);
    let singleArticleTop = 80;
    const restoreRects = installRects(element => {
      if (element.classList.contains('tabs-bar__wrapper')) {
        return box(0, 64);
      }

      if (element.classList.contains('scrollable')) {
        return element.getAttribute('data-pane') === 'history' ? box(100, 700) : box(0, 900);
      }

      if (element.tagName === 'ARTICLE' && element.getAttribute('data-id') === '90') {
        const pane = element.parentElement.getAttribute('data-pane');

        return pane === 'history' ? box(140, 260) : box(singleArticleTop, singleArticleTop + 120);
      }

      if (element.tagName === 'ARTICLE') {
        return box(-40, 10);
      }

      return box(0, 0);
    });
    const { container } = renderHome(store, { multiColumn: false });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    singleArticleTop = 500;
    fireEvent.click(screen.getByRole('button', { name: 'Close live pane' }));
    restoreRects();

    expect(container.querySelector('.timeline-split')).toBeNull();
    expect(scroller().scrollTop).toBe(396);
  });

  it('scrolls the live pane from the header while single-column home is split', () => {
    const store = buildStore();
    const { container } = renderHome(store, { multiColumn: false });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const live = container.querySelector('.timeline-split__pane--live .scrollable');
    const history = container.querySelector('.timeline-split__pane--history .scrollable');
    const documentScroller = scroller();

    live.scrollTo = jest.fn();
    history.scrollTo = jest.fn();
    documentScroller.scrollTo = jest.fn();
    documentScroller.scrollTop = 240;

    fireEvent.click(screen.getByRole('button', { name: 'Home' }));

    expect(live.scrollTo).toHaveBeenCalledWith({ behavior: 'smooth', top: 0 });
    expect(history.scrollTo).not.toHaveBeenCalled();
    expect(documentScroller.scrollTo).not.toHaveBeenCalled();
    expect(documentScroller.scrollTop).toBe(240);
  });

  it('discards the single-column anchor when a partial home is unsplit', () => {
    const store = buildStore();
    mountTabsWrapper(0, 64);
    const restoreRects = installRects(element => {
      if (element.classList.contains('tabs-bar__wrapper')) {
        return box(0, 64);
      }

      if (element.classList.contains('scrollable')) {
        return element.getAttribute('data-pane') === 'history' ? box(100, 700) : box(0, 900);
      }

      if (element.tagName === 'ARTICLE' && element.getAttribute('data-id') === '90') {
        const pane = element.parentElement.getAttribute('data-pane');

        return pane === 'history' ? box(140, 260) : box(500, 620);
      }

      return box(-40, 10);
    });
    const { container } = renderHome(store, { multiColumn: false });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    act(() => {
      store.dispatch({ type: 'TIMELINE_MARK_AS_PARTIAL', timeline: 'home' });
    });

    fireEvent.click(document.querySelector('.column-header__split-button'));

    expect(container.querySelector('.scrollable')).toBeNull();
    expect(scroller().scrollTop).toBe(0);

    act(() => {
      store.dispatch({
        type: 'TIMELINE_EXPAND_SUCCESS',
        timeline: 'home',
        statuses: [{ id: '200' }],
        next: '199',
        partial: false,
        isLoadingRecent: false,
        usePendingItems: false,
      });
    });
    restoreRects();

    expect(container.querySelector('.scrollable').scrollTop).toBe(0);
    expect(scroller().scrollTop).toBe(0);
    expect(store.getState().getIn(['timelines', 'home', 'isPartial'])).toBe(false);
  });

  it('removes the split when the layout mode changes in either direction', () => {
    const store = buildStore();
    const multi = render(
      <Provider store={store}>
        <HomeTimeline columnId='col-layout' multiColumn />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = expectSplitId(store, 'col-layout');

    multi.rerender(
      <Provider store={store}>
        <HomeTimeline columnId='col-layout' multiColumn={false} />
      </Provider>,
    );

    expect(store.getState().hasIn(['timelines', splitTimelineId])).toBe(false);
    expect(activeSplitId(store)).toBeUndefined();
    multi.unmount();

    const single = renderHome(store, { columnId: 'col-layout', multiColumn: false });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const nextSplitId = expectSplitId(store, 'col-layout');

    single.rerender(
      <Provider store={store}>
        <HomeTimeline columnId='col-layout' multiColumn />
      </Provider>,
    );

    expect(store.getState().hasIn(['timelines', nextSplitId])).toBe(false);
    expect(activeSplitId(store)).toBeUndefined();
    expect(document.body.classList.contains('status-timeline-split')).toBe(false);
  });

  const homeLocation = (key) => ({ key, pathname: '/timelines/home' });

  const flushQueuedFrames = (frames) => {
    const batch = frames.splice(0, frames.length);

    act(() => {
      batch.forEach(callback => callback(0));
    });
  };

  it('saves a return anchor when single-column home leaves while split', () => {
    const store = buildStore();
    const restoreRects = installRects(element => {
      if (element.classList.contains('scrollable') && element.getAttribute('data-pane') === 'history') {
        return box(100, 700);
      }

      if (element.tagName === 'ARTICLE' && element.getAttribute('data-id') === '90') {
        return box(92.16, 200);
      }

      if (element.tagName === 'ARTICLE') {
        return box(0, 90);
      }

      return box(0, 0);
    });
    const view = renderHome(store, { columnId: 'col-nav', multiColumn: false, location: homeLocation('1g1nyt') });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = expectSplitId(store, 'col-nav');
    view.container.querySelector('.timeline-split__pane--history .scrollable').scrollTop = 2386;
    view.unmount();
    restoreRects();

    const anchor = store.getState().getIn(['timelines', 'home', 'splitReturnAnchor']);

    expect(store.getState().hasIn(['timelines', splitTimelineId])).toBe(false);
    expect(store.getState().getIn(['timelines', 'home', 'splitTimelineId'])).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'home', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(anchor.get('locationKey')).toBe('1g1nyt');
    expect(anchor.get('id')).toBe('90');
    expect(anchor.get('offset')).toBeCloseTo(-7.84);
    expect(anchor.get('fallbackOffset')).toBe(2386);
  });

  it('restores the return anchor into the document when the same location key mounts', () => {
    const store = buildStore();

    store.dispatch({
      type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR',
      timeline: 'home',
      anchor: { locationKey: 'A', id: '90', offset: -7.84, fallbackOffset: 2386 },
    });
    mountTabsWrapper(0, 64);
    const restoreRects = installRects(element => {
      if (element.classList.contains('tabs-bar__wrapper')) {
        return box(0, 64);
      }

      if (element.classList.contains('scrollable')) {
        return box(0, 900);
      }

      if (element.tagName === 'ARTICLE' && element.getAttribute('data-id') === '90') {
        const top = 400 - scroller().scrollTop;

        return box(top, top + 120);
      }

      return box(-40, 10);
    });
    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });

    scroller().scrollTop = 0;
    renderHome(store, { multiColumn: false, location: homeLocation('A') });
    flushQueuedFrames(frames);
    flushQueuedFrames(frames);
    spy.mockRestore();
    restoreRects();

    expect(scroller().scrollTop).toBeCloseTo(343.84);
    expect(store.getState().getIn(['timelines', 'home', 'splitReturnAnchor'])).toBeUndefined();
  });

  it('discards a return anchor when home mounts on a different location key', () => {
    const store = buildStore();

    store.dispatch({
      type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR',
      timeline: 'home',
      anchor: { locationKey: 'A', id: '90', offset: -7.84, fallbackOffset: 2386 },
    });
    mountTabsWrapper(0, 64);
    const restoreRects = installRects(element => {
      if (element.classList.contains('tabs-bar__wrapper')) {
        return box(0, 64);
      }

      if (element.classList.contains('scrollable')) {
        return box(0, 900);
      }

      if (element.tagName === 'ARTICLE' && element.getAttribute('data-id') === '90') {
        return box(400, 520);
      }

      return box(-40, 10);
    });
    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });

    scroller().scrollTop = 80;
    renderHome(store, { multiColumn: false, location: homeLocation('B') });
    flushQueuedFrames(frames);
    spy.mockRestore();
    restoreRects();

    expect(scroller().scrollTop).toBe(80);
    expect(store.getState().getIn(['timelines', 'home', 'splitReturnAnchor'])).toBeUndefined();
  });

  it('clears a return anchor when the same location key mounts in multiple columns', () => {
    const store = buildStore();

    store.dispatch({
      type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR',
      timeline: 'home',
      anchor: { locationKey: 'A', id: '90', offset: -7.84, fallbackOffset: 2386 },
    });
    mountTabsWrapper(0, 64);
    const restoreRects = installRects(element => {
      if (element.classList.contains('tabs-bar__wrapper')) {
        return box(0, 64);
      }

      if (element.classList.contains('scrollable')) {
        return box(0, 900);
      }

      if (element.tagName === 'ARTICLE' && element.getAttribute('data-id') === '90') {
        return box(400, 520);
      }

      return box(-40, 10);
    });
    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });

    scroller().scrollTop = 80;
    const { container } = renderHome(store, { columnId: 'col-multi', multiColumn: true, location: homeLocation('A') });
    flushQueuedFrames(frames);
    spy.mockRestore();
    restoreRects();

    expect(scroller().scrollTop).toBe(80);
    expect(container.querySelector('.timeline-split')).toBeNull();
    expect(store.getState().getIn(['timelines', 'home', 'splitReturnAnchor'])).toBeUndefined();
  });

  it('cancels a queued return restore when a new split starts', () => {
    const store = buildStore();

    store.dispatch({
      type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR',
      timeline: 'home',
      anchor: { locationKey: 'A', id: '90', offset: -7.84, fallbackOffset: 2386 },
    });
    mountTabsWrapper(0, 64);
    const restoreRects = installRects(element => {
      if (element.classList.contains('tabs-bar__wrapper')) {
        return box(0, 64);
      }

      if (element.classList.contains('scrollable')) {
        return element.getAttribute('data-pane') === 'history' ? box(100, 700) : box(0, 900);
      }

      if (element.tagName === 'ARTICLE' && element.getAttribute('data-id') === '90') {
        const top = 400 - scroller().scrollTop;

        return box(top, top + 120);
      }

      return box(-40, 10);
    });
    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });

    scroller().scrollTop = 0;
    const { container } = renderHome(store, { columnId: 'col-cancel', multiColumn: false, location: homeLocation('A') });
    const staleRestore = frames[0];

    expect(staleRestore).toEqual(expect.any(Function));
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    act(() => {
      staleRestore(0);
    });
    spy.mockRestore();
    restoreRects();

    expect(scroller().scrollTop).toBe(0);
    expect(container.querySelector('.timeline-split')).not.toBeNull();
    expect(activeSplitId(store)).toEqual(expect.stringMatching(/^home:split:col-cancel:/));
    expect(store.getState().getIn(['timelines', 'home', 'splitReturnAnchor'])).toBeUndefined();
  });

  it('does not save a return anchor when a partial single-column split unmounts', () => {
    const store = buildStore();
    const { unmount } = renderHome(store, { columnId: 'col-partial', multiColumn: false, location: homeLocation('A') });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = expectSplitId(store, 'col-partial');

    act(() => {
      store.dispatch({ type: 'TIMELINE_MARK_AS_PARTIAL', timeline: 'home' });
    });
    unmount();

    expect(store.getState().hasIn(['timelines', splitTimelineId])).toBe(false);
    expect(store.getState().getIn(['timelines', 'home', 'splitReturnAnchor'])).toBeUndefined();
  });
});
