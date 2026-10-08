/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { STATUS_TIMELINE_SPLIT_LAYOUT_CLASS } from '../../ui/components/status_timeline_split_controller';
import settings from 'mastodon/reducers/settings';
import timelines from 'mastodon/reducers/timelines';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/initial_state', () => ({
  ...jest.requireActual('mastodon/initial_state'),
  isAdministrator: true,
}));

const mockGet = jest.fn(() => new Promise(() => {}));

jest.mock('mastodon/api', () => {
  const api = jest.fn(() => ({ get: mockGet, put: jest.fn(() => Promise.resolve({ data: {} })) }));

  return {
    __esModule: true,
    default: api,
    getLinks: () => ({ refs: [] }),
  };
});

jest.mock('../../../actions/lists', () => ({
  fetchList: id => ({ type: 'LIST_FETCH', id }),
  deleteList: id => ({ type: 'LIST_DELETE', id }),
  updateList: (...args) => ({ type: 'LIST_UPDATE', args }),
}));

const streamLog = [];

jest.mock('../../../actions/streaming', () => ({
  connectListStream: (id) => () => {
    streamLog.push(`connect:${id}`);

    return () => {
      streamLog.push(`disconnect:${id}`);
    };
  },
}));

jest.mock('../../../components/missing_indicator', () => () => null);
jest.mock('../../../components/loading_indicator', () => () => null);

jest.mock('../../compose/portable_composer', () => {
  const React = require('react');

  return function PortableComposer ({ composerId }) {
    return <div data-testid='portable-composer' data-composer-id={composerId} />;
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
    } else if (props.dataTimelineId && props.dataTimelineId !== props.timelineId) {
      pane = 'history';
    }

    if (isPartial) {
      return <div data-regenerating='true' data-pane={pane} data-timeline={timelineId} data-context={props.timelineId} />;
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
        data-prepend={props.prepend ? 'true' : 'false'}
        data-always-prepend={props.alwaysPrepend ? 'true' : 'false'}
      >
        {props.prepend}
        {ids.map(id => <article key={id} data-id={id} />)}
        {props.onLoadMore && <button type='button' data-testid={`load-${pane}`} onClick={() => props.onLoadMore('70')}>Load more</button>}
      </div>
    );
  };
});

import ListTimeline from '../index';

const lists = (state = ImmutableMap(), action) => {
  if (action.type === 'LIST_TEST_SET') {
    return action.lists;
  }

  return state;
};

const friendList = (id, title) => fromJS({ id, title, replies_policy: 'list' });

const buildStore = (listMap = { 42: friendList('42', 'Friends') }) => {
  const reducer = combineReducers({ timelines, settings, lists });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state.set('lists', ImmutableMap(listMap));
  Object.keys(listMap).forEach(id => {
    if (!listMap[id]) {
      return;
    }

    state = state.setIn(['timelines', `list:${id}`], ImmutableMap({
      unread: 0,
      online: true,
      top: false,
      isLoading: false,
      hasMore: true,
      isPartial: false,
      pendingItems: ImmutableList(['120']),
      items: ImmutableList(['100', '90', '80']),
    }));
  });

  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderList = (store, props) => render(
  <Provider store={store}>
    <ListTimeline params={{ id: '42' }} {...props} />
  </Provider>,
);

const listLocation = (key, id = '42') => ({ key, pathname: `/timelines/list/${id}` });

const activeSplitId = (store, id = '42') => store.getState().getIn(['timelines', `list:${id}`, 'splitTimelineId']);

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

const pinInnerScroller = (column, scrollTop) => {
  const node = column.querySelector('.scrollable');

  Object.defineProperty(node, 'scrollHeight', { configurable: true, value: 2400 });
  Object.defineProperty(node, 'clientHeight', { configurable: true, value: 500 });
  node.scrollTop = scrollTop;

  return node;
};

let anchorFrameSpy;
let anchorCancelSpy;

const installAnchorTimers = () => {
  jest.useFakeTimers();
  anchorFrameSpy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => setTimeout(callback, 0));
  anchorCancelSpy = jest.spyOn(window, 'cancelAnimationFrame').mockImplementation(id => clearTimeout(id));
};

const flushAnchorTimers = () => {
  act(() => {
    jest.runAllTimers();
  });
};

const restoreAnchorTimers = () => {
  if (anchorFrameSpy) {
    anchorFrameSpy.mockRestore();
    anchorFrameSpy = null;
  }

  if (anchorCancelSpy) {
    anchorCancelSpy.mockRestore();
    anchorCancelSpy = null;
  }

  jest.useRealTimers();
};

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

const flushQueuedFrames = (frames) => {
  const batch = frames.splice(0, frames.length);

  act(() => {
    batch.forEach(callback => callback(0));
  });
};

describe('ListTimeline split', () => {
  beforeEach(() => {
    streamLog.length = 0;
    mockGet.mockClear();

    const portal = document.createElement('div');
    portal.id = 'tabs-bar__portal';
    document.body.appendChild(portal);
  });

  afterEach(() => {
    document.querySelectorAll('.tabs-bar__wrapper').forEach(node => node.remove());
    document.body.classList.remove(STATUS_TIMELINE_SPLIT_LAYOUT_CLASS);

    const portal = document.getElementById('tabs-bar__portal');

    if (portal) {
      portal.remove();
    }
  });

  it('shows a split button without replacing the list settings', () => {
    const store = buildStore();
    renderList(store, { columnId: 'col-a', multiColumn: true });

    expect(screen.getByRole('button', { name: 'Split timeline' })).toBeEnabled();
    fireEvent.click(screen.getByRole('button', { name: 'Show settings' }));
    expect(screen.getByText('Edit list')).toBeTruthy();
    expect(screen.getByText('Delete list')).toBeTruthy();
    expect(screen.getByText('Show replies to:')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    expect(screen.getByText('Edit list')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Remove timeline split', pressed: true })).toBeEnabled();
  });

  it('uses the canonical list timeline for the live pane and the temporary timeline for history', () => {
    const store = buildStore();
    const { container } = renderList(store, { columnId: 'col-a', multiColumn: true });

    expect(streamLog).toEqual(['connect:42']);
    expect(container.querySelector('.scrollable').getAttribute('data-context')).toBe('list:42');

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const splitTimelineId = activeSplitId(store);
    const live = container.querySelector('.timeline-split__pane--live .scrollable');
    const history = container.querySelector('.timeline-split__pane--history .scrollable');

    expect(splitTimelineId).toEqual(expect.stringMatching(/^list:42:split:col-a:.+/));
    expect(live.getAttribute('data-context')).toBe('list:42');
    expect(live.getAttribute('data-timeline')).toBe('list:42');
    expect(history.getAttribute('data-context')).toBe('list:42');
    expect(history.getAttribute('data-timeline')).toBe(splitTimelineId);
    expect(live.getAttribute('data-track-intersection')).toBe('false');
    expect(live.getAttribute('data-manage-scroll')).toBe('false');
    expect(live.getAttribute('data-track-scroll')).toBe('false');
    expect(live.getAttribute('data-bind')).toBe('column');
    expect(history.getAttribute('data-track-intersection')).toBe('true');
    expect(history.getAttribute('data-bind')).toBe('column');
    expect(container.querySelector('[data-testid="load-live"]')).toBeNull();
    expect(container.querySelector('[data-testid="load-history"]')).not.toBeNull();
    expect(streamLog).toEqual(['connect:42']);
  });

  it('writes history load-more onto the temporary timeline and keeps the list API', () => {
    const store = buildStore();
    const { container } = renderList(store, { columnId: 'col-a', multiColumn: true });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = activeSplitId(store);
    const callsBefore = mockGet.mock.calls.length;

    fireEvent.click(container.querySelector('[data-testid="load-history"]'));

    expect(store.getState().getIn(['timelines', splitTimelineId, 'isLoading'])).toBe(true);
    expect(store.getState().getIn(['timelines', 'list:42', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(mockGet.mock.calls.length).toBe(callsBefore + 1);
    expect(mockGet).toHaveBeenLastCalledWith('/api/v1/timelines/list/42', expect.objectContaining({
      params: expect.objectContaining({ max_id: '70' }),
    }));
    expect(streamLog).toEqual(['connect:42']);
  });

  it('places the portable composer only on the live pane while it is visible', () => {
    const store = buildStore();
    const { container } = renderList(store, { columnId: 'col-a', multiColumn: true });
    const composerId = 'portable:list-column:col-a';

    expect(container.querySelector('[data-testid="portable-composer"]')).toBeNull();
    expect(screen.getByRole('button', { name: 'Show composer' }).getAttribute('aria-pressed')).toBe('false');

    fireEvent.click(screen.getByRole('button', { name: 'Show composer' }));

    expect(store.getState().getIn(['settings', 'portableComposerVisibility', composerId])).toBe(true);
    expect(screen.getByRole('button', { name: 'Hide composer' }).getAttribute('aria-pressed')).toBe('true');
    expect(container.querySelectorAll('[data-testid="portable-composer"]')).toHaveLength(1);
    expect(container.querySelector('[data-testid="portable-composer"]').getAttribute('data-composer-id')).toBe(composerId);

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const live = container.querySelector('.timeline-split__pane--live .scrollable');
    const history = container.querySelector('.timeline-split__pane--history .scrollable');

    expect(container.querySelectorAll('.timeline-split__pane--live [data-testid="portable-composer"]')).toHaveLength(1);
    expect(container.querySelectorAll('.timeline-split__pane--history [data-testid="portable-composer"]')).toHaveLength(0);
    expect(live.getAttribute('data-prepend')).toBe('true');
    expect(live.getAttribute('data-always-prepend')).toBe('true');
    expect(history.getAttribute('data-prepend')).toBe('false');
    expect(history.getAttribute('data-always-prepend')).toBe('false');
    expect(store.getState().getIn(['settings', 'portableComposerVisibility', composerId])).toBe(true);

    fireEvent.click(screen.getByRole('button', { name: 'Hide composer' }));

    expect(container.querySelectorAll('.timeline-split__pane--live [data-testid="portable-composer"]')).toHaveLength(0);
    expect(container.querySelectorAll('.timeline-split__pane--history [data-testid="portable-composer"]')).toHaveLength(0);
    expect(store.getState().getIn(['settings', 'portableComposerVisibility', composerId])).toBe(false);

    fireEvent.click(screen.getByRole('button', { name: 'Show composer' }));
    fireEvent.click(screen.getByRole('button', { name: 'Remove timeline split', pressed: true }));

    expect(container.querySelector('.timeline-split')).toBeNull();
    expect(container.querySelectorAll('[data-testid="portable-composer"]')).toHaveLength(1);
    expect(store.getState().getIn(['settings', 'portableComposerVisibility', composerId])).toBe(true);
  });

  it('keeps list composer visibility independent for each column', () => {
    const store = buildStore();

    store.dispatch({
      type: 'SETTING_CHANGE',
      path: ['portableComposerVisibility', 'portable:list-column:col-a'],
      value: true,
    });
    store.dispatch({
      type: 'SETTING_CHANGE',
      path: ['portableComposerVisibility', 'portable:list-column:col-b'],
      value: false,
    });

    const { container } = render(
      <Provider store={store}>
        <div data-testid='column-a'>
          <ListTimeline params={{ id: '42' }} columnId='col-a' multiColumn />
        </div>
        <div data-testid='column-b'>
          <ListTimeline params={{ id: '42' }} columnId='col-b' multiColumn />
        </div>
      </Provider>,
    );

    expect(container.querySelectorAll('[data-testid="column-a"] [data-testid="portable-composer"]')).toHaveLength(1);
    expect(container.querySelector('[data-testid="column-a"] [data-testid="portable-composer"]').getAttribute('data-composer-id')).toBe('portable:list-column:col-a');
    expect(container.querySelectorAll('[data-testid="column-b"] [data-testid="portable-composer"]')).toHaveLength(0);
    expect(store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:list-column:col-a'])).toBe(true);
    expect(store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:list-column:col-b'])).toBe(false);
  });

  it('keeps the other same-titled list still when this column shows its composer', () => {
    const store = buildStore({
      42: friendList('42', 'Friends'),
      7: friendList('7', 'Friends'),
    });
    const { container } = render(
      <Provider store={store}>
        <div data-column='a'>
          <ListTimeline params={{ id: '42' }} columnId='col-a' multiColumn />
        </div>
        <div data-column='b'>
          <ListTimeline params={{ id: '7' }} columnId='col-b' multiColumn />
        </div>
      </Provider>,
    );
    const columnA = container.querySelector('[data-column="a"] .column');
    const columnB = container.querySelector('[data-column="b"] .column');
    const scrollerA = pinInnerScroller(columnA, 500);
    const scrollerB = pinInnerScroller(columnB, 700);
    const originalRect = HTMLElement.prototype.getBoundingClientRect;

    HTMLElement.prototype.getBoundingClientRect = function () {
      if (this.classList.contains('scrollable')) {
        return box(0, 500);
      }

      if (this.tagName === 'ARTICLE') {
        const host = this.closest('[data-column]');
        const inner = host && host.querySelector('.scrollable');
        const which = host && host.getAttribute('data-column');
        const composer = host && host.querySelector('[data-testid="portable-composer"]');
        const initial = which === 'b' ? 700 : 500;
        let base = 20;

        if (which === 'b') {
          base = composer ? 240 : 80;
        }

        const top = base - ((inner ? inner.scrollTop : 0) - initial);

        return box(top, top + 60);
      }

      return box(0, 0);
    };

    const buttonB = container.querySelector('[data-column="b"] button[aria-label="Show composer"]');

    expect(columnA.getAttribute('aria-label')).toBe('Friends');
    expect(columnB.getAttribute('aria-label')).toBe('Friends');
    expect(columnA).not.toBe(columnB);
    expect(buttonB.closest('.column')).toBe(columnB);

    try {
      installAnchorTimers();
      fireEvent.click(buttonB);
      flushAnchorTimers();

      expect(scrollerA.scrollTop).toBe(500);
      expect(scrollerB.scrollTop).toBe(860);
      expect(store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:list-column:col-a'])).toBeUndefined();
      expect(store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:list-column:col-b'])).toBe(true);
    } finally {
      HTMLElement.prototype.getBoundingClientRect = originalRect;
      restoreAnchorTimers();
    }
  });

  it('restores history onto the canonical list when the live pane is closed', () => {
    const store = buildStore();
    const { container } = renderList(store, { columnId: 'col-a', multiColumn: true });

    container.querySelector('.scrollable').scrollTop = 320;
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = activeSplitId(store);

    act(() => {
      store.dispatch({
        type: 'TIMELINE_EXPAND_SUCCESS',
        timeline: splitTimelineId,
        statuses: [{ id: '70' }],
        next: null,
        partial: false,
        isLoadingRecent: false,
        usePendingItems: false,
      });
      store.dispatch({
        type: 'TIMELINE_UPDATE',
        timeline: 'list:42',
        status: { id: '130' },
        usePendingItems: false,
      });
    });

    const history = container.querySelector('.timeline-split__pane--history .scrollable');
    history.scrollTop = 480;
    fireEvent.click(screen.getByRole('button', { name: 'Close live pane' }));

    expect(container.querySelector('.timeline-split')).toBeNull();
    expect(container.querySelector('.scrollable').scrollTop).toBe(480);
    expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
    expect(store.getState().getIn(['timelines', 'list:42', 'items'])).toEqual(ImmutableList(['100', '90', '80', '70']));
    expect(store.getState().getIn(['timelines', 'list:42', 'pendingItems'])).toEqual(ImmutableList(['130', '120']));
  });

  it('restores the visible status into the single-column history pane', () => {
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
    const { container } = renderList(store, { multiColumn: false, location: listLocation('A') });

    scroller().scrollTop = 900;
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    restoreRects();

    const history = container.querySelector('.timeline-split__pane--history .scrollable');
    const live = container.querySelector('.timeline-split__pane--live .scrollable');

    expect(history.scrollTop).toBe(384);
    expect(scroller().scrollTop).toBe(0);
    expect(history.getAttribute('data-track-scroll')).toBe('false');
    expect(live.getAttribute('data-bind')).toBe('column');
    expect(history.getAttribute('data-bind')).toBe('column');
    expect(document.body.classList.contains(STATUS_TIMELINE_SPLIT_LAYOUT_CLASS)).toBe(true);
  });

  it('restores a return anchor when the same list location is mounted again', () => {
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

        if (pane === 'history') {
          return box(92.16, 200);
        }

        const top = 400 - scroller().scrollTop;

        return box(top, top + 120);
      }

      return box(-40, 10);
    });
    const view = renderList(store, { multiColumn: false, location: listLocation('route-a') });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    view.container.querySelector('.timeline-split__pane--history .scrollable').scrollTop = 2386;
    view.unmount();

    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor', 'locationKey'])).toBe('route-a');
    expect(streamLog).toEqual(['connect:42', 'disconnect:42']);

    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });

    scroller().scrollTop = 0;
    renderList(store, { multiColumn: false, location: listLocation('route-a') });
    flushQueuedFrames(frames);
    flushQueuedFrames(frames);
    spy.mockRestore();
    restoreRects();

    expect(scroller().scrollTop).toBeCloseTo(343.84);
    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor'])).toBeUndefined();
    expect(streamLog).toEqual(['connect:42', 'disconnect:42', 'connect:42']);
  });

  it('does not restore a return anchor for a different location key', () => {
    const store = buildStore();
    const view = renderList(store, { multiColumn: false, location: listLocation('route-a') });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    view.container.querySelector('.timeline-split__pane--history .scrollable').scrollTop = 900;
    view.unmount();

    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });

    scroller().scrollTop = 80;
    renderList(store, { multiColumn: false, location: listLocation('route-b') });
    flushQueuedFrames(frames);
    spy.mockRestore();

    expect(scroller().scrollTop).toBe(80);
    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor'])).toBeUndefined();
  });

  it('cleans up the previous list split when the list id changes', () => {
    const store = buildStore({
      42: friendList('42', 'Friends'),
      99: friendList('99', 'News'),
    });
    const view = render(
      <Provider store={store}>
        <ListTimeline params={{ id: '42' }} multiColumn={false} location={listLocation('route-a', '42')} />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = activeSplitId(store, '42');

    view.container.querySelector('.timeline-split__pane--history .scrollable').scrollTop = 640;
    view.rerender(
      <Provider store={store}>
        <ListTimeline params={{ id: '99' }} multiColumn={false} location={listLocation('route-b', '99')} />
      </Provider>,
    );

    expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
    expect(activeSplitId(store, '42')).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor', 'locationKey'])).toBe('route-a');
    expect(activeSplitId(store, '99')).toBeUndefined();
    expect(view.container.querySelector('.timeline-split')).toBeNull();
    expect(view.container.querySelector('.scrollable').getAttribute('data-context')).toBe('list:99');
    expect(streamLog).toEqual(['connect:42', 'disconnect:42', 'connect:99']);
    expect(screen.getByRole('button', { name: 'News' })).toBeTruthy();
  });

  it('disables split on another column of the same list and allows a different list to split', () => {
    const store = buildStore({
      42: friendList('42', 'Friends'),
      99: friendList('99', 'News'),
    });
    const sameList = render(
      <Provider store={store}>
        <ListTimeline params={{ id: '42' }} columnId='col-a' multiColumn />
        <ListTimeline params={{ id: '42' }} columnId='col-b' multiColumn />
      </Provider>,
    );
    let buttons = sameList.container.querySelectorAll('.column-header__split-button');

    fireEvent.click(buttons[0]);
    buttons = sameList.container.querySelectorAll('.column-header__split-button');

    expect(buttons[0]).toHaveAttribute('aria-pressed', 'true');
    expect(buttons[1]).toBeDisabled();
    expect(buttons[1]).toHaveAttribute('aria-label', 'This list is already split in another column');
    expect(streamLog.filter(entry => entry.startsWith('connect:'))).toEqual(['connect:42', 'connect:42']);
    sameList.unmount();

    streamLog.length = 0;
    const differentLists = render(
      <Provider store={store}>
        <ListTimeline params={{ id: '42' }} columnId='col-a' multiColumn />
        <ListTimeline params={{ id: '99' }} columnId='col-b' multiColumn />
      </Provider>,
    );
    const nextButtons = differentLists.container.querySelectorAll('.column-header__split-button');

    fireEvent.click(nextButtons[0]);
    fireEvent.click(nextButtons[1]);

    expect(activeSplitId(store, '42')).toEqual(expect.stringMatching(/^list:42:split:col-a:.+/));
    expect(activeSplitId(store, '99')).toEqual(expect.stringMatching(/^list:99:split:col-b:.+/));
    expect(differentLists.container.querySelectorAll('.timeline-split')).toHaveLength(2);
    expect(nextButtons[0]).toHaveAttribute('aria-pressed', 'true');
    expect(nextButtons[1]).toHaveAttribute('aria-pressed', 'true');
    expect(streamLog.filter(entry => entry.startsWith('connect:'))).toEqual(['connect:42', 'connect:99']);
  });

  it('hides split UI while a list is loading or missing, and cleans up if the list disappears', () => {
    const loadingStore = buildStore({});
    const loading = renderList(loadingStore, { multiColumn: true });

    expect(loading.container.querySelector('.column-header__split-button')).toBeNull();
    loading.unmount();

    const missingStore = buildStore({ 42: false });
    const missing = renderList(missingStore, { multiColumn: false });

    expect(missing.container.querySelector('.column-header__split-button')).toBeNull();
    expect(missing.container.querySelector('.timeline-split')).toBeNull();
    missing.unmount();

    const store = buildStore();
    renderList(store, { columnId: 'col-a', multiColumn: true });
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = activeSplitId(store);

    act(() => {
      store.dispatch({ type: 'LIST_TEST_SET', lists: ImmutableMap({ 42: false }) });
    });

    expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
    expect(activeSplitId(store)).toBeUndefined();
    expect(document.querySelector('.column-header__split-button')).toBeNull();
  });
});