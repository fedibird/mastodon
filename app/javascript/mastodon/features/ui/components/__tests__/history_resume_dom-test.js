/* eslint-disable react/prop-types, react/jsx-no-bind */
// jsdom dispatches the scroll, wheel, touch, pointer, and key events below.
// It does not replace a real Chromium layout pass.

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import { act, cleanup, fireEvent, render } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('mastodon/containers/status_container', () => () => null);
jest.mock('mastodon/containers/scroll_container', () => ({ children }) => children);
jest.mock('mastodon/components/regeneration_indicator', () => () => null);
jest.mock('mastodon/components/load_gap', () => () => null);
jest.mock('mastodon/components/reload_zone', () => () => null);
jest.mock('mastodon/components/load_window_edge', () => () => null);
jest.mock('mastodon/filter_reconciliation/surface', () => ({
  FilterSurface: class {

    update () {}

    destroy () {}

    intersection () {}

    prepare () {}

  },
}));

const mockGet = jest.fn();
const mockPost = jest.fn();

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ get: mockGet, post: mockPost })),
  getLinks: () => ({ refs: [] }),
}));

jest.mock('mastodon/actions/importer', () => ({
  importFetchedStatuses: () => ({ type: 'IMPORT_STATUSES' }),
  importFetchedAccounts: () => ({ type: 'IMPORT_ACCOUNTS' }),
  importFetchedStatus: () => ({ type: 'IMPORT_STATUS' }),
}));

jest.mock('mastodon/actions/accounts', () => ({
  fetchRelationshipsSuccess: () => ({ type: 'REL_SUCCESS' }),
  fetchRelationshipsFromStatuses: () => ({ type: 'REL_STATUSES' }),
}));

jest.mock('mastodon/initial_state', () => ({
  ...jest.requireActual('mastodon/initial_state'),
  isAdministrator: true,
}));

import { captureHistoryPosition, resumeHistoryPosition } from 'mastodon/actions/timeline_position';
import { TIMELINE_SPLIT_CREATE, saveTimelineSplitReturnAnchor } from 'mastodon/actions/timelines';
import { settleWindowSeekScroll } from 'mastodon/actions/timeline_seek';
import StatusList from 'mastodon/components/status_list';
import timelines from 'mastodon/reducers/timelines';
import { historySourceIdentity, historyViewIdentity } from 'mastodon/timeline_position/identity';
import { resetPositionRegistry, getPositionRegistry } from 'mastodon/timeline_position/session';
import { resetHistorySurfaces, subscribeHistorySurface } from 'mastodon/timeline_position/surface';
import { homeHistoryContract } from 'mastodon/windowed_history/sources';
import StatusTimelineSplitController from '../status_timeline_split_controller';

const contract = homeHistoryContract(['public']);
const source = historySourceIdentity('home', contract);

const viewFor = (columnId, locationKey = 'entry-a') => historyViewIdentity({
  columnId,
  sourceTimelineId: 'home',
  locationKey,
});

const anchorFor = (statusId, offsetPx = 12) => ({
  version: 1,
  statusId,
  displayRowId: statusId,
  offsetPx,
  alignment: 'top',
  capturedAt: '2026-10-17T00:00:00.000Z',
});

const remember = (statusId, columnId = 'column-a', offsetPx = 12) => captureHistoryPosition({
  accountId: '1',
  source,
  view: viewFor(columnId),
  anchor: anchorFor(statusId, offsetPx),
  routeEntryKey: 'entry-a',
  layout: 'single',
  sync: true,
});

const root = (state = ImmutableMap(), action) => state.set('timelines', timelines(state.get('timelines'), action));

const createHarnessStore = () => {
  const state = ImmutableMap({
    timelines: ImmutableMap({
      home: ImmutableMap({
        unread: 0,
        online: true,
        top: true,
        isLoading: false,
        hasMore: true,
        pendingItems: ImmutableList(),
        items: ImmutableList(['300', '200', '100']),
      }),
    }),
  });

  return createStore(root, state, applyMiddleware(thunk));
};

const openSplit = (store, splitId) => {
  store.dispatch({
    type: TIMELINE_SPLIT_CREATE,
    sourceTimeline: 'home',
    splitTimeline: splitId,
    anchorId: '200',
  });
};

let reduxStore = null;
let scrollList = null;
let userScrolls = 0;
let unsubscribeScrolls = null;

class RouterShim extends React.Component {

  static childContextTypes = {
    router: () => null,
  };

  getChildContext () {
    return {
      router: {
        history: {
          action: this.props.action || null,
          listen: () => () => {},
          location: this.props.location || { key: 'entry-a' },
        },
        route: {
          location: this.props.location || { key: 'entry-a' },
        },
      },
    };
  }

  render () {
    return this.props.children;
  }

}

class HistoryPane extends React.Component {

  componentDidMount () {
    this.unsubscribe = reduxStore.subscribe(() => {
      if (!this.unmounted) {
        this.forceUpdate();
      }
    });
  }

  componentWillUnmount () {
    this.unmounted = true;

    if (this.unsubscribe) {
      this.unsubscribe();
    }
  }

  setList = (list) => {
    scrollList = list;
  }

  render () {
    const dataId = this.props.dataId;
    const items = reduxStore.getState().getIn(['timelines', dataId, 'items'], ImmutableList());
    const seek = reduxStore.getState().getIn(['timelines', dataId, 'seek']);
    const revision = reduxStore.getState().getIn(['timelines', dataId, 'window', 'revision']) || 0;
    const pending = !!(
      seek
      && seek.get('phase') === 'resolved'
      && seek.get('scrollStatus') === 'pending'
      && seek.get('scrollRevision') === revision
      && seek.get('anchorId')
    );

    return (
      <StatusList
        ref={this.setList}
        scrollKey={`${dataId}:history`}
        timelineId='home'
        statusIds={items.filter(id => id)}
        trackScroll={false}
        trackIntersection={false}
        hasMore={false}
        isLoading={false}
        windowedHistory
        windowRevision={revision}
        seekScrollPending={pending}
        seekSessionId={pending ? seek.get('id') : null}
        seekAnchorId={pending ? seek.get('anchorId') : null}
        seekScrollRevision={pending ? revision : 0}
        historySurfaceId={dataId}
        onSeekScroll={(result) => reduxStore.dispatch(settleWindowSeekScroll(dataId, result))}
      />
    );
  }

}

const Column = ({
  columnId = 'column-a',
  accountId = '1',
  location = { key: 'entry-a' },
  action = null,
}) => (
  <RouterShim action={action} location={location}>
    <StatusTimelineSplitController
      sourceTimelineId='home'
      columnId={columnId}
      accountId={accountId}
      historyContract={contract}
      location={location}
      multiColumn={false}
      splitRatio={50}
      unavailableMessage={{ id: 'timeline.split_unavailable', defaultMessage: 'Unavailable' }}
      onSplitRatioCommit={() => {}}
    >
      {split => (
        <div>
          {split.resumeButton}
          {split.splitButton}
          {split.closeLiveButton}
          {split.isSplit && (
            <div className='timeline-split__pane--history'>
              <HistoryPane dataId={split.splitTimelineId} />
            </div>
          )}
        </div>
      )}
    </StatusTimelineSplitController>
  </RouterShim>
);

const rect = (top, height) => ({
  top,
  bottom: top + height,
  left: 0,
  right: 320,
  width: 320,
  height,
  x: 0,
  y: top,
  toJSON () {},
});

const layoutArticles = (list, heights) => {
  const articles = Array.from(list.querySelectorAll('article[data-id]'));

  articles.forEach((article) => {
    article.getBoundingClientRect = () => {
      let offset = 0;

      articles.some((item) => {
        if (item === article) {
          return true;
        }

        offset += heights[item.getAttribute('data-id')] || 0;

        return false;
      });

      return rect(offset - list.scrollTop, heights[article.getAttribute('data-id')] || 0);
    };
  });
  list.getBoundingClientRect = () => rect(0, 500);
};

const installScrollTop = (list) => {
  let top = 0;
  const queued = [];
  const metrics = {
    queue: false,
    release () {
      const batch = queued.splice(0, queued.length);

      batch.forEach(emit => emit());
    },
  };

  Object.defineProperty(list, 'scrollTop', {
    configurable: true,
    get: () => top,
    set (value) {
      const next = Number(value) || 0;

      if (next === top) {
        return;
      }

      top = next;

      const emit = () => list.dispatchEvent(new Event('scroll'));

      if (metrics.queue) {
        queued.push(emit);
      } else {
        emit();
      }
    },
  });
  Object.defineProperty(list, 'scrollHeight', {
    configurable: true,
    get: () => 4000,
  });
  Object.defineProperty(list, 'clientHeight', {
    configurable: true,
    get: () => 500,
  });

  return metrics;
};

const heightsFor = (extra = {}) => ({
  300: 100,
  200: 100,
  100: 100,
  70: 100,
  60: 100,
  50: 100,
  40: 100,
  ...extra,
});

describe('history resume DOM', () => {
  let frames;

  beforeEach(() => {
    frames = [];
    userScrolls = 0;
    scrollList = null;
    reduxStore = createHarnessStore();
    resetPositionRegistry();
    resetHistorySurfaces();
    mockGet.mockReset();
    mockPost.mockReset();
    mockGet.mockImplementation((path, config = {}) => {
      if (String(path).indexOf('/api/v1/statuses/') === 0) {
        return Promise.resolve({ data: { id: String(path).split('/').pop() } });
      }

      const params = config.params || {};

      if (params.min_id) {
        return Promise.resolve({ status: 200, data: [{ id: '70' }, { id: '60' }] });
      }

      return Promise.resolve({ status: 200, data: [{ id: '40' }] });
    });
    global.IntersectionObserver = class {

      observe () {}

      unobserve () {}

      disconnect () {}

      takeRecords () {
        return [];
      }

    };
    jest.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => {
      frames.push(callback);
      return frames.length;
    });
    jest.spyOn(window, 'cancelAnimationFrame').mockImplementation((id) => {
      frames[id - 1] = null;
    });
  });

  afterEach(() => {
    if (unsubscribeScrolls) {
      unsubscribeScrolls();
      unsubscribeScrolls = null;
    }

    cleanup();
    document.body.innerHTML = '';
    jest.restoreAllMocks();
  });

  const flushFrames = () => {
    let guard = 0;

    while (frames.length && guard < 8) {
      const batch = frames.splice(0, frames.length);

      act(() => {
        batch.forEach(callback => callback && callback(0));
      });
      guard += 1;
    }
  };

  const watchScrolls = (splitId) => {
    unsubscribeScrolls = subscribeHistorySurface(splitId, (event) => {
      if (event.type === 'scroll') {
        userScrolls += 1;
      }
    });
  };

  const sendPointer = (node, type, pointerType, buttons = 0) => {
    const view = node.ownerDocument.defaultView;
    let event;

    try {
      event = new view.PointerEvent(type, {
        bubbles: true,
        cancelable: true,
        pointerType,
        buttons,
      });
    } catch (error) {
      event = new view.MouseEvent(type, { bubbles: true, cancelable: true, buttons });
    }

    if (event.pointerType !== pointerType) {
      Object.defineProperty(event, 'pointerType', { value: pointerType });
    }

    if (event.buttons !== buttons) {
      Object.defineProperty(event, 'buttons', { configurable: true, value: buttons });
    }

    node.dispatchEvent(event);
  };

  const renderColumn = (props = {}) => render(
    <Provider store={reduxStore}>
      <Column key={props.columnId || 'column-a'} {...props} />
    </Provider>,
  );

  const historyList = (view) => view.container.querySelector('.timeline-split__pane--history .scrollable');

  const prepareList = (view, heights = heightsFor()) => {
    const list = historyList(view);
    const metrics = installScrollTop(list);

    layoutArticles(list, heights);

    return { list, metrics };
  };

  const resumeExplicit = (splitId, columnId = 'column-a') => reduxStore.dispatch(resumeHistoryPosition({
    accountId: '1',
    sourceTimelineId: 'home',
    splitTimelineId: splitId,
    contract,
    source,
    view: viewFor(columnId),
    locationKey: 'entry-b',
    historyAction: 'PUSH',
    explicit: true,
    multiColumn: false,
  }));

  const phase = (splitId) => reduxStore.getState().getIn(['timelines', splitId, 'historyResume', 'phase']) || null;

  const flushScroll = () => {
    if (scrollList && scrollList.node) {
      scrollList.node.handleScroll.flush();
    }
  };

  const resolvedSeek = {
    version: 1,
    outcome: 'resolved',
    capability: 'approximate',
    precision: 'exact',
    anchor_id: '50',
    display_row_id: '50',
    limitations: [],
  };

  it('does not treat an in-window restore scroll as a reader gesture', async () => {
    const splitId = 'home:split:column-a:session-1';

    openSplit(reduxStore, splitId);
    remember('100');
    watchScrolls(splitId);
    const view = renderColumn();
    const { list, metrics } = prepareList(view);
    const heights = heightsFor();

    metrics.queue = true;

    await act(async () => {
      await resumeExplicit(splitId);
    });

    expect(phase(splitId)).toBe('restored');
    expect(userScrolls).toBe(0);
    expect(list.scrollTop).toBe(188);

    metrics.release();
    flushScroll();
    fireEvent.scroll(list);
    flushScroll();

    expect(userScrolls).toBe(0);
    expect(phase(splitId)).toBe('restored');
    expect(getPositionRegistry().find('1', source, viewFor('column-a')).position.anchor).toMatchObject({
      statusId: '100',
      offsetPx: 12,
    });

    metrics.queue = false;
    heights['300'] = 180;
    layoutArticles(list, heights);
    flushFrames();
    flushScroll();
    fireEvent.scroll(list);
    flushScroll();

    expect(list.scrollTop).toBe(268);
    expect(userScrolls).toBe(0);
    expect(phase(splitId)).toBe('restored');
  });

  it('keeps a synchronous in-window scroll event synthetic', async () => {
    const splitId = 'home:split:column-a:session-1';

    openSplit(reduxStore, splitId);
    remember('100');
    watchScrolls(splitId);
    const view = renderColumn();

    prepareList(view);

    await act(async () => {
      await resumeExplicit(splitId);
    });
    flushScroll();
    flushScroll();

    expect(userScrolls).toBe(0);
    expect(phase(splitId)).toBe('restored');
    expect(historyList(view).scrollTop).toBe(188);
  });

  it('scrolls the armed anchor after a seek commit and marks scrollStatus loaded', async () => {
    const splitId = 'home:split:column-a:session-1';

    openSplit(reduxStore, splitId);
    remember('50');
    watchScrolls(splitId);
    const view = renderColumn();
    const { list, metrics } = prepareList(view);

    mockPost.mockResolvedValue({ data: resolvedSeek });
    metrics.queue = true;

    await act(async () => {
      await resumeExplicit(splitId);
    });

    expect(phase(splitId)).toBe('scroll_pending');
    expect(reduxStore.getState().getIn(['timelines', splitId, 'seek', 'scrollStatus'])).toBe('pending');
    expect(list.scrollTop).toBe(0);

    layoutArticles(list, heightsFor());
    flushFrames();

    expect(list.scrollTop).toBe(188);
    expect(phase(splitId)).toBe('restored');
    expect(reduxStore.getState().getIn(['timelines', splitId, 'seek', 'scrollStatus'])).toBe('loaded');
    expect(userScrolls).toBe(0);

    metrics.release();
    flushScroll();
    fireEvent.scroll(list);
    flushScroll();

    expect(userScrolls).toBe(0);
    expect(phase(splitId)).toBe('restored');
    expect(reduxStore.getState().getIn(['timelines', splitId, 'seek', 'scrollStatus'])).toBe('loaded');
    expect(getPositionRegistry().find('1', source, viewFor('column-a')).position.anchor.statusId).toBe('50');
  });

  it('does not scroll when a wheel arrives before the seek frame', async () => {
    const splitId = 'home:split:column-a:session-1';

    openSplit(reduxStore, splitId);
    remember('50');
    const view = renderColumn();
    const { list } = prepareList(view);
    const itemsBefore = reduxStore.getState().getIn(['timelines', splitId, 'items']);

    mockPost.mockResolvedValue({ data: resolvedSeek });

    await act(async () => {
      await resumeExplicit(splitId);
    });

    expect(phase(splitId)).toBe('scroll_pending');
    fireEvent.wheel(list);
    layoutArticles(list, heightsFor());
    flushFrames();

    expect(list.scrollTop).toBe(0);
    expect(phase(splitId)).not.toBe('restored');
    expect(reduxStore.getState().getIn(['timelines', splitId, 'seek', 'scrollStatus'])).not.toBe('loaded');
    expect(reduxStore.getState().getIn(['timelines', splitId, 'items'])).not.toEqual(itemsBefore);
  });

  it('stops an in-flight seek on wheel, touch, pointer, keyboard, and a dragged scroll', async () => {
    const splitId = 'home:split:column-a:session-1';

    openSplit(reduxStore, splitId);
    remember('50');
    const view = renderColumn();
    const { list } = prepareList(view);
    const input = document.createElement('input');

    list.appendChild(input);

    const arm = () => {
      let resolvePost;

      mockPost.mockReturnValue(new Promise(resolve => {
        resolvePost = resolve;
      }));
      fireEvent.click(view.getByRole('button', { name: 'Resume saved place' }));
      expect(phase(splitId)).toBe('seek_pending');

      return resolvePost;
    };

    const finish = async (resolvePost) => {
      await act(async () => {
        resolvePost({ data: resolvedSeek });
        await Promise.resolve();
        await Promise.resolve();
      });
    };

    let resolvePost = arm();

    sendPointer(list, 'pointerdown', 'mouse', 1);
    sendPointer(list, 'pointermove', 'mouse', 0);
    fireEvent.click(list);
    fireEvent.keyDown(input, { key: ' ' });
    expect(phase(splitId)).toBe('seek_pending');

    const gestures = [
      (node) => fireEvent.wheel(node),
      (node) => fireEvent.touchMove(node),
      (node) => sendPointer(node, 'pointerdown', 'touch', 1),
      (node) => sendPointer(node, 'pointerdown', 'pen', 1),
      (node) => sendPointer(node, 'pointermove', 'mouse', 1),
      (node) => fireEvent.keyDown(node, { key: 'ArrowDown' }),
      (node) => fireEvent.keyDown(node, { key: 'PageDown' }),
      (node) => fireEvent.keyDown(node, { key: ' ' }),
      (node) => {
        node.scrollTop = (node.scrollTop || 0) + 40;
        flushScroll();
      },
    ];

    const itemsAtArm = reduxStore.getState().getIn(['timelines', splitId, 'items']);

    for (let index = 0; index < gestures.length; index += 1) {
      if (index > 0) {
        resolvePost = arm();
      }

      gestures[index](list);
      expect({ index, phase: phase(splitId) }).toEqual({ index, phase: 'cancelled' });
      await finish(resolvePost);
      expect(reduxStore.getState().getIn(['timelines', splitId, 'items'])).toEqual(itemsAtArm);
    }
  });

  it('keeps separate positions for two columns of the same source and flushes them when History closes', () => {
    const splitId = 'home:split:column-a:session-1';

    openSplit(reduxStore, splitId);
    const view = renderColumn({ columnId: 'column-a' });
    const first = prepareList(view);

    first.list.scrollTop = 200;
    fireEvent.click(view.getByRole('button', { name: 'Remove timeline split' }));

    expect(getPositionRegistry().find('1', source, viewFor('column-a')).position.anchor.statusId).toBe('100');
    expect(view.container.querySelector('.timeline-split__pane--history')).toBeNull();

    view.rerender(
      <Provider store={reduxStore}>
        <Column key='column-b' columnId='column-b' />
      </Provider>,
    );
    fireEvent.click(view.getByRole('button', { name: 'Split timeline' }));

    const secondList = historyList(view);
    const secondSplit = reduxStore.getState().getIn(['timelines', 'home', 'splitTimelineId']);

    installScrollTop(secondList);
    layoutArticles(secondList, heightsFor());
    secondList.scrollTop = 0;
    fireEvent.click(view.getByRole('button', { name: 'Remove timeline split' }));

    expect(getPositionRegistry().find('1', source, viewFor('column-b')).position.anchor.statusId).toBe('300');
    expect(getPositionRegistry().find('1', source, viewFor('column-a')).position.anchor.statusId).toBe('100');
    expect(secondSplit).not.toBe(splitId);

    view.rerender(
      <Provider store={reduxStore}>
        <Column key='column-a' columnId='column-a' />
      </Provider>,
    );
    mockPost.mockResolvedValue({ data: resolvedSeek });
    fireEvent.click(view.getByRole('button', { name: 'Split timeline' }));

    expect(mockPost).not.toHaveBeenCalled();
    expect(reduxStore.getState().getIn(['timelines', reduxStore.getState().getIn(['timelines', 'home', 'splitTimelineId']), 'historyResume'])).toBeUndefined();

    fireEvent.click(view.getByRole('button', { name: 'Resume saved place' }));

    expect(reduxStore.getState().getIn([
      'timelines',
      reduxStore.getState().getIn(['timelines', 'home', 'splitTimelineId']),
      'historyResume',
      'anchorStatusId',
    ])).toBe('100');
    expect(getPositionRegistry().find('1', source, viewFor('column-b')).position.anchor.statusId).toBe('300');
  });

  it('flushes the open history pane when Keep History closes the live pane', () => {
    const splitId = 'home:split:column-a:session-1';

    openSplit(reduxStore, splitId);
    const view = renderColumn();
    const { list } = prepareList(view);

    list.scrollTop = 200;
    fireEvent.click(view.getByRole('button', { name: 'Close live pane' }));

    expect(getPositionRegistry().find('1', source, viewFor('column-a')).position.anchor.statusId).toBe('100');
    expect(reduxStore.getState().getIn(['timelines', 'home', 'splitTimelineId']) || null).toBeNull();

    fireEvent.click(view.getByRole('button', { name: 'Split timeline' }));
    expect(mockPost).not.toHaveBeenCalled();
    expect(reduxStore.getState().getIn(['timelines', reduxStore.getState().getIn(['timelines', 'home', 'splitTimelineId']), 'historyResume'])).toBeUndefined();
  });

  it('auto-resumes only for POP on the same entry when History is open and the row is outside the window', async () => {
    const splitId = 'home:split:column-a:session-1';

    mockPost.mockResolvedValue({ data: resolvedSeek });

    const mountOpen = (props, { returnAnchor = false } = {}) => {
      remember('50');
      openSplit(reduxStore, splitId);

      if (returnAnchor) {
        reduxStore.dispatch(saveTimelineSplitReturnAnchor('home', {
          locationKey: 'entry-a',
          id: '200',
          offset: 0,
          fallbackOffset: 0,
        }));
      } else {
        reduxStore.dispatch({ type: 'TIMELINE_SPLIT_CLEAR_RETURN_ANCHOR', timeline: 'home' });
      }

      return renderColumn(props);
    };

    const pushed = mountOpen({ action: 'PUSH' });

    expect(mockPost).not.toHaveBeenCalled();
    expect(phase(splitId)).toBeNull();
    pushed.unmount();

    const anchored = mountOpen({ action: 'POP' }, { returnAnchor: true });

    expect(mockPost).not.toHaveBeenCalled();
    expect(phase(splitId)).toBeNull();
    anchored.unmount();

    const otherEntry = mountOpen({ action: 'POP', location: { key: 'entry-b' } });

    expect(mockPost).not.toHaveBeenCalled();
    expect(phase(splitId)).toBeNull();
    otherEntry.unmount();

    remember('50');
    const closed = renderColumn({ action: 'POP' });

    expect(reduxStore.getState().getIn(['timelines', 'home', 'splitTimelineId']) || null).toBeNull();
    expect(mockPost).not.toHaveBeenCalled();
    closed.unmount();

    const popped = mountOpen({ action: 'POP' });

    await act(async () => {
      await new Promise(resolve => {
        setTimeout(resolve, 0);
      });
    });

    expect(mockPost).toHaveBeenCalled();
    expect(phase(splitId)).toBe('scroll_pending');
    expect(popped.container.querySelector('.timeline-split__pane--history')).not.toBeNull();
  });

  it('ignores a late seek commit after the reader moves to another column', async () => {
    const splitId = 'home:split:column-a:session-1';

    openSplit(reduxStore, splitId);
    remember('50');
    const view = renderColumn({ columnId: 'column-a' });

    prepareList(view);

    let resolvePost;

    mockPost.mockReturnValue(new Promise(resolve => {
      resolvePost = resolve;
    }));
    fireEvent.click(view.getByRole('button', { name: 'Resume saved place' }));
    expect(phase(splitId)).toBe('seek_pending');

    const homeItems = reduxStore.getState().getIn(['timelines', 'home', 'items']);

    view.rerender(
      <Provider store={reduxStore}>
        <Column key='column-b' columnId='column-b' />
      </Provider>,
    );
    fireEvent.click(view.getByRole('button', { name: 'Split timeline' }));
    const otherList = historyList(view);

    installScrollTop(otherList);
    expect(otherList.scrollTop).toBe(0);

    await act(async () => {
      resolvePost({ data: resolvedSeek });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(reduxStore.getState().getIn(['timelines', 'home', 'items'])).toEqual(homeItems);
    expect(reduxStore.getState().getIn(['timelines', splitId, 'items'])).toBeUndefined();
    expect(otherList.scrollTop).toBe(0);
    expect(reduxStore.getState().getIn(['timelines', 'home', 'items']).includes('50')).toBe(false);
  });

  it('drops the previous account when the signed-in account changes', () => {
    const splitId = 'home:split:column-a:session-1';

    openSplit(reduxStore, splitId);
    remember('100');
    const view = renderColumn({ accountId: '1' });

    expect(view.getByRole('button', { name: 'Resume saved place' })).not.toBeNull();

    view.rerender(
      <Provider store={reduxStore}>
        <Column key='column-a' accountId='2' />
      </Provider>,
    );

    expect(view.queryByRole('button', { name: 'Resume saved place' })).toBeNull();
    expect(getPositionRegistry().find('1', source, viewFor('column-a'))).toBeNull();
    expect(getPositionRegistry().find('2', source, viewFor('column-a'))).toBeNull();
  });
});
