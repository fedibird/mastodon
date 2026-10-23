import { act, cleanup, render } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { MemoryRouter } from 'react-router-dom';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => {
  const ReactMock = require('react');
  const intl = {
    formatMessage: (message, values) => {
      let text = (message && (message.defaultMessage || message.id)) || '';

      if (values) {
        Object.keys(values).forEach(key => {
          text = text.split(`{${key}}`).join(String(values[key]));
        });
      }

      return text;
    },
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => ReactMock.createElement(Component, { ...props, intl }),
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/containers/scroll_container', () => ({ children }) => children);
jest.mock('mastodon/components/regeneration_indicator', () => () => null);
jest.mock('mastodon/components/load_gap', () => () => null);
jest.mock('mastodon/components/reload_zone', () => () => null);
jest.mock('mastodon/components/load_window_edge', () => ({ HistoryAnchorNotice: () => null }));

jest.mock('../../../containers/status_container', () => {
  const ReactMock = require('react');

  return () => ReactMock.createElement('span', null);
});

import { MixTimelinePage } from '../timeline';

const intl = {
  formatMessage: (message, values) => {
    let text = message.defaultMessage || message.id || '';

    if (values) {
      Object.keys(values).forEach(key => {
        text = text.split(`{${key}}`).join(String(values[key]));
      });
    }

    return text;
  },
};

const mix = fromJS({
  id: 'mix-1',
  title: 'Desk',
  version: 1,
  sources: [
    { type: 'home', params: {} },
    { type: 'public', params: {} },
  ],
});

const reduxStore = () => createStore(() => ImmutableMap({
  dropdown_menu: ImmutableMap(),
  height_cache: ImmutableMap(),
  filterMatches: ImmutableMap({ baseline: true, generation: 0, entries: ImmutableMap() }),
  statuses: ImmutableMap(),
}), applyMiddleware(thunk));

const pane = (ids) => ({
  statusIds: ImmutableList(ids),
  reconciliationIds: ImmutableList(['100', '200']),
  orderGuaranteed: true,
  waiting: false,
  running: false,
  hasMore: false,
  contextById: {},
  warningsById: {},
  sourceKeysById: {},
  suspended: [],
  errors: [],
  incomplete: [],
  pendingCount: 0,
  degraded: [],
  offline: [],
  restOnly: [],
});

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

const layout = (list, heights) => {
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

      const top = offset - (list.scrollTop || 0);

      return rect(top, heights[article.getAttribute('data-id')] || 0);
    };
  });

  list.getBoundingClientRect = () => rect(0, 600);
};

const openScrollRange = (list) => {
  Object.defineProperty(list, 'scrollHeight', { configurable: true, get: () => 8000 });
  Object.defineProperty(list, 'clientHeight', { configurable: true, get: () => 600 });
};

const listProps = (node) => {
  const key = Object.keys(node).find(name => name.startsWith('__reactInternalInstance$') || name.startsWith('__reactFiber$'));
  let fiber = key ? node[key] : null;

  while (fiber) {
    if (fiber.memoizedProps && Object.prototype.hasOwnProperty.call(fiber.memoizedProps, 'anchorSourceKey')) {
      return fiber.memoizedProps;
    }

    fiber = fiber.return;
  }

  return null;
};

describe('mix history reading anchor', () => {
  let frames;
  let observers;

  const flushFrames = () => {
    let guard = 0;

    while (frames.some(Boolean) && guard < 8) {
      const batch = frames.splice(0, frames.length);

      act(() => {
        batch.forEach(callback => callback && callback(0));
      });
      guard += 1;
    }
  };

  const intersect = (article) => {
    const entry = {
      target: article,
      isIntersecting: true,
      intersectionRatio: 1,
      boundingClientRect: article.getBoundingClientRect(),
    };

    act(() => {
      observers.forEach((observer) => {
        if (observer.nodes.has(article)) {
          observer.callback([entry]);
        }
      });
    });
  };

  beforeEach(() => {
    frames = [];
    observers = [];
    global.requestIdleCallback = (callback) => {
      callback({ didTimeout: false, timeRemaining: () => 50 });
      return 0;
    };
    global.cancelIdleCallback = () => {};
    Object.defineProperty(document, 'hidden', { configurable: true, value: false });
    document.body.style.overflow = '';
    global.IntersectionObserver = class {

      constructor (callback) {
        this.callback = callback;
        this.nodes = new Set();
        observers.push(this);
      }

      observe (node) {
        this.nodes.add(node);
      }

      unobserve (node) {
        this.nodes.delete(node);
      }

      disconnect () {
        this.nodes.clear();
      }

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
    cleanup();
    document.body.innerHTML = '';
    document.body.style.overflow = '';
    jest.restoreAllMocks();
    jest.useRealTimers();
  });

  const renderMix = (store, props) => {
    const tree = (next) => (
      <Provider store={store}>
        <MemoryRouter>
          <MixTimelinePage
            dispatch={jest.fn()}
            intl={intl}
            mixId='mix-1'
            mix={mix}
            columnId='alpha'
            columnKey='desk'
            multiColumn
            splitRatio={35}
            lists={ImmutableMap()}
            accounts={ImmutableMap()}
            {...props}
            {...next}
          />
        </MemoryRouter>
      </Provider>
    );
    const view = render(tree());

    return { view, tree };
  };

  const unhideAbove = (list, heights) => {
    openScrollRange(list);
    layout(list, heights);
    list.scrollTop = 0;
    intersect(list.querySelector('article[data-id="100"]'));
  };

  const listInstance = (node) => {
    const key = Object.keys(node).find(name => name.startsWith('__reactInternalInstance$') || name.startsWith('__reactFiber$'));
    let fiber = key ? node[key] : null;

    while (fiber) {
      if (fiber.stateNode && typeof fiber.stateNode.handleMouseIdle === 'function') {
        return fiber.stateNode;
      }

      fiber = fiber.return;
    }

    return null;
  };

  const trackElementScroll = (node) => {
    let top = node.scrollTop || 0;
    let deliveries = 0;

    node.addEventListener('scroll', () => {
      deliveries += 1;
    });
    Object.defineProperty(node, 'scrollTop', {
      configurable: true,
      get: () => top,
      set (value) {
        top = Number(value) || 0;
        node.dispatchEvent(new Event('scroll'));
      },
    });

    return {
      deliveries: () => deliveries,
    };
  };

  const settleMouseIdle = async () => {
    await act(async () => {
      await new Promise((resolve) => {
        setTimeout(resolve, 350);
      });
    });
  };

  it('keeps the mix history row in place when a newer filtered post reappears at local 0', () => {
    const store = reduxStore();
    const heights = { 100: 200, 200: 200 };
    const mounted = renderMix(store, {
      splitId: 'desk:split:alpha:1',
      view: pane(['100']),
      liveView: pane(['100']),
      historyView: pane(['100']),
    });
    const history = mounted.view.container.querySelector('.timeline-split__pane--history .scrollable');
    const live = mounted.view.container.querySelector('.timeline-split__pane--live .scrollable');

    expect(history).not.toBeNull();
    expect(live).not.toBeNull();
    unhideAbove(history, heights);
    unhideAbove(live, heights);
    mounted.view.rerender(mounted.tree({
      splitId: 'desk:split:alpha:1',
      view: pane(['200', '100']),
      liveView: pane(['200', '100']),
      historyView: pane(['200', '100']),
    }));

    const historyList = mounted.view.container.querySelector('.timeline-split__pane--history .scrollable');
    const liveList = mounted.view.container.querySelector('.timeline-split__pane--live .scrollable');
    const historyProps = listProps(historyList);
    const liveProps = listProps(liveList);

    layout(historyList, heights);
    layout(liveList, heights);
    flushFrames();
    expect(historyList.scrollTop).toBe(200);
    expect(historyList.querySelector('article[data-id="100"]').getBoundingClientRect().top).toBe(0);
    expect(liveList.scrollTop).toBe(0);
    expect(historyProps.windowedHistory).toBe(false);
    expect(historyProps.readingSurface).toBe(true);
    expect(liveProps.readingSurface).not.toBe(true);
    expect(liveProps.windowedHistory).toBe(false);
  });

  it('keeps the mix history row in place when the mouse idles after a filtered post is inserted above it', async () => {
    const store = reduxStore();
    const heights = { 100: 200, 200: 200 };
    const mounted = renderMix(store, {
      splitId: 'desk:split:alpha:1',
      view: pane(['100']),
      liveView: pane(['100']),
      historyView: pane(['100']),
    });
    const history = mounted.view.container.querySelector('.timeline-split__pane--history .scrollable');
    const live = mounted.view.container.querySelector('.timeline-split__pane--live .scrollable');
    const historyApi = listInstance(history);
    const liveApi = listInstance(live);

    openScrollRange(history);
    openScrollRange(live);
    layout(history, heights);
    layout(live, heights);
    jest.spyOn(historyApi, 'getScrollHeight').mockImplementation(() => history.querySelectorAll('article[data-id]').length * 200);
    jest.spyOn(liveApi, 'getScrollHeight').mockImplementation(() => live.querySelectorAll('article[data-id]').length * 200);
    const historyScroll = trackElementScroll(history);
    const liveScroll = trackElementScroll(live);

    history.scrollTop = 0;
    live.scrollTop = 0;
    historyApi.handleScroll.flush();
    liveApi.handleScroll.flush();
    historyApi.handleMouseMove();
    historyApi.handleMouseMove.flush();
    liveApi.handleMouseMove();
    liveApi.handleMouseMove.flush();
    expect(historyApi.scrollToTopOnMouseIdle).toBe(false);
    expect(liveApi.scrollToTopOnMouseIdle).toBe(true);

    const historyBefore = historyScroll.deliveries();
    const liveBefore = liveScroll.deliveries();

    mounted.view.rerender(mounted.tree({
      splitId: 'desk:split:alpha:1',
      view: pane(['200', '100']),
      liveView: pane(['200', '100']),
      historyView: pane(['200', '100']),
    }));

    const historyList = mounted.view.container.querySelector('.timeline-split__pane--history .scrollable');
    const liveList = mounted.view.container.querySelector('.timeline-split__pane--live .scrollable');

    layout(historyList, heights);
    layout(liveList, heights);
    expect(historyScroll.deliveries()).toBeGreaterThan(historyBefore);
    expect(liveScroll.deliveries()).toBeGreaterThan(liveBefore);
    expect(historyApi.lastScrollWasSynthetic).toBe(true);
    historyApi.handleScroll.flush();
    liveApi.handleScroll.flush();
    expect(historyApi.lastScrollWasSynthetic).toBe(false);
    expect(historyList.scrollTop).toBe(200);
    expect(liveList.scrollTop).toBe(200);
    await settleMouseIdle();
    expect(historyList.scrollTop).toBe(200);
    expect(historyList.querySelector('article[data-id="100"]').getBoundingClientRect().top).toBe(0);
    expect(liveList.scrollTop).toBe(0);
    expect(listProps(historyList).windowedHistory).toBe(false);
    expect(listProps(historyList).readingSurface).toBe(true);
  });

  it('keeps following the latest row on a single mix column at the top', () => {
    const store = reduxStore();
    const heights = { 100: 200, 200: 200 };
    const mounted = renderMix(store, {
      view: pane(['100']),
    });
    const list = mounted.view.container.querySelector('.scrollable');

    expect(mounted.view.container.querySelector('.timeline-split__pane--history')).toBeNull();
    unhideAbove(list, heights);
    mounted.view.rerender(mounted.tree({
      view: pane(['200', '100']),
    }));

    const next = mounted.view.container.querySelector('.scrollable');

    layout(next, heights);
    flushFrames();
    expect(listProps(next).readingSurface).not.toBe(true);
    expect(listProps(next).windowedHistory).toBe(false);
    expect(next.scrollTop).toBe(0);
  });
});
