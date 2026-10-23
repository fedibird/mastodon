jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
  FormattedMessage: () => null,
  FormattedNumber: () => null,
}));

import { act, render } from '@testing-library/react';
import { createMemoryHistory } from 'history';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { Router } from 'react-router-dom';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('../../containers/scroll_container', () => ({ children }) => children);
jest.mock('../regeneration_indicator', () => () => null);
jest.mock('../load_gap', () => () => null);
jest.mock('../reload_zone', () => () => null);
jest.mock('../load_window_edge', () => () => null);
jest.mock('../../containers/status_container', () => {
  const ReactMock = require('react');

  return () => ReactMock.createElement('span', null);
});

import ScrollableList from '../scrollable_list';
import StatusList from '../status_list';

const reduxStore = () => createStore(() => ImmutableMap({
  dropdown_menu: ImmutableMap(),
  filterMatches: ImmutableMap({ baseline: true, generation: 0, entries: ImmutableMap() }),
  statuses: ImmutableMap(),
}), applyMiddleware(thunk));

const Row = () => <span />;

const items = (ids) => ids.map(id => <Row key={id} />);

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

const layout = (list, heights, { origin = 0, scroller = list } = {}) => {
  const articles = Array.from(list.querySelectorAll('article[data-id]'));

  articles.forEach((article) => {
    article.getBoundingClientRect = () => {
      let offset = origin;

      articles.some((item) => {
        if (item === article) {
          return true;
        }

        offset += heights[item.getAttribute('data-id')] || 0;

        return false;
      });

      const top = offset - (scroller.scrollTop || 0);

      return rect(top, heights[article.getAttribute('data-id')] || 0);
    };
  });

  list.getBoundingClientRect = () => rect(origin, 600);
};

describe('timeline filter anchor follow', () => {
  let frames;
  let observers;

  const flushFrames = (count = Infinity) => {
    let guard = 0;
    const limit = count === Infinity ? 8 : count;

    while (frames.some(Boolean) && guard < limit) {
      const batch = count === Infinity ? frames.splice(0, frames.length) : frames.splice(0, 1);

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
    document.body.innerHTML = '';
    document.body.style.overflow = '';
    jest.restoreAllMocks();
    jest.useRealTimers();
  });

  const mount = ({ bindToDocument = false, windowedHistory = false, anchorSourceKey = 'public:stream', ids = ['100'], scrollKey = 'public' } = {}) => {
    const ref = React.createRef();
    const store = reduxStore();
    const scrollerFor = (list) => (bindToDocument ? (document.scrollingElement || document.documentElement) : list);

    if (bindToDocument) {
      const scroller = document.documentElement;

      Object.defineProperty(document, 'scrollingElement', { configurable: true, get: () => scroller });
      Object.defineProperty(scroller, 'scrollHeight', { configurable: true, get: () => 8000 });
      Object.defineProperty(scroller, 'clientHeight', { configurable: true, get: () => 600 });
    }

    const tree = (nextIds, extra = {}) => (
      <Provider store={store}>
        <ScrollableList
          ref={ref}
          scrollKey={extra.scrollKey || scrollKey}
          trackScroll={false}
          hasMore={false}
          bindToDocument={bindToDocument}
          windowedHistory={Object.prototype.hasOwnProperty.call(extra, 'windowedHistory') ? extra.windowedHistory : windowedHistory}
          anchorSourceKey={extra.anchorSourceKey || anchorSourceKey}
          filterStatusIds={['100', '90', '80', '200', '300']}
        >
          {items(nextIds)}
        </ScrollableList>
      </Provider>
    );
    const view = render(tree(ids));
    const list = view.container.querySelector('.scrollable');
    const scroller = scrollerFor(list);

    return { view, ref, list, scroller, tree, store };
  };

  const article = (list, id) => list.querySelector(`article[data-id="${id}"]`);

  it('does not pin the previous row when a live timeline prepends while following', () => {
    const mounted = mount();
    const { view, list, scroller, tree } = mounted;
    const heights = { 100: 200, 200: 200 };

    layout(list, heights);
    scroller.scrollTop = 0;
    intersect(article(list, '100'));
    view.rerender(tree(['200', '100']));
    layout(view.container.querySelector('.scrollable'), heights);
    flushFrames();
    expect(scroller.scrollTop).toBe(0);
  });

  it('does not pin a document timeline when the list top is at the reading edge', () => {
    const mounted = mount({ bindToDocument: true, anchorSourceKey: 'public:stream' });
    const { view, list, scroller, tree } = mounted;
    const heights = { 100: 200, 200: 200 };

    layout(list, heights, { origin: 0, scroller });
    scroller.scrollTop = 0;
    intersect(article(list, '100'));
    view.rerender(tree(['200', '100']));
    layout(view.container.querySelector('.scrollable'), heights, { origin: 0, scroller });
    flushFrames();
    expect(scroller.scrollTop).toBe(0);
  });

  it('does not capture a document list whose top is below the reading edge', () => {
    const mounted = mount({ bindToDocument: true });
    const { view, ref, list, scroller, tree } = mounted;
    const heights = { 100: 200, 200: 200 };

    layout(list, heights, { origin: 56, scroller });
    scroller.scrollTop = 0;
    intersect(article(list, '100'));
    expect(ref.current.filterSurface.frame).toBeNull();
    view.rerender(tree(['200', '100']));
    layout(view.container.querySelector('.scrollable'), heights, { origin: 56, scroller });
    flushFrames();
    expect(scroller.scrollTop).toBe(0);
  });

  it('moves focus off a removed row without leaving the latest edge', () => {
    const mounted = mount();
    const { view, list, scroller, tree } = mounted;
    const heights = { 100: 200, 200: 200 };
    const row = article(list, '100');
    const button = document.createElement('button');

    layout(list, heights);
    row.appendChild(button);
    button.focus();
    intersect(row);
    button.remove();
    view.rerender(tree(['200', '100']));
    const nextList = view.container.querySelector('.scrollable');

    layout(nextList, heights);
    flushFrames();
    expect(scroller.scrollTop).toBe(0);
    expect(nextList.contains(document.activeElement)).toBe(true);
    expect(document.activeElement).not.toBe(button);
  });

  it('preserves a windowed history row at local scroll 0', () => {
    const mounted = mount({ windowedHistory: true, anchorSourceKey: 'public:history' });
    const { view, list, scroller, tree } = mounted;
    const heights = { 100: 200, 200: 200 };

    layout(list, heights);
    scroller.scrollTop = 0;
    intersect(article(list, '100'));
    view.rerender(tree(['200', '100']));
    layout(view.container.querySelector('.scrollable'), heights);
    flushFrames();
    expect(scroller.scrollTop).toBe(200);
  });

  it('preserves a row the reader has moved to, including inside the 100px unread band', () => {
    const mounted = mount({ ids: ['100', '90'] });
    const { list, scroller } = mounted;
    const heights = { 100: 50, 90: 200 };

    layout(list, heights);
    scroller.scrollTop = 80;
    intersect(article(list, '90'));
    heights['100'] = 250;
    flushFrames();
    expect(scroller.scrollTop).toBe(280);
  });

  it('does not rewind a subpixel move while a reading anchor is pending', () => {
    const mounted = mount({ ids: ['100', '90'] });
    const { list, scroller } = mounted;
    const heights = { 100: 200, 90: 200 };

    layout(list, heights);
    scroller.scrollTop = 350;
    intersect(article(list, '90'));
    scroller.scrollTop = 350.75;
    heights['100'] = 400;
    flushFrames();
    expect(scroller.scrollTop).toBe(350.75);
  });

  it('keeps correcting a real height change while the reader is down the timeline', () => {
    const mounted = mount({ ids: ['100', '90'] });
    const { list, scroller } = mounted;
    const heights = { 100: 200, 90: 200 };

    layout(list, heights);
    scroller.scrollTop = 350;
    intersect(article(list, '90'));
    heights['100'] = 0;
    flushFrames();
    expect(scroller.scrollTop).toBe(150);
  });

  it('does not let one column follow-correction move the other column', () => {
    const live = React.createRef();
    const history = React.createRef();
    const store = reduxStore();
    const tree = (liveIds, historyIds) => (
      <Provider store={store}>
        <div>
          <ScrollableList ref={live} scrollKey='public-live' trackScroll={false} hasMore={false} windowedHistory={false} anchorSourceKey='public:stream' filterStatusIds={['100', '200']}>
            {items(liveIds)}
          </ScrollableList>
          <ScrollableList ref={history} scrollKey='public-history' trackScroll={false} hasMore={false} windowedHistory anchorSourceKey='public:history' filterStatusIds={['100', '200']}>
            {items(historyIds)}
          </ScrollableList>
        </div>
      </Provider>
    );
    const view = render(tree(['100'], ['100']));
    const lists = () => view.container.querySelectorAll('.scrollable');
    const heights = { 100: 200, 200: 200 };

    layout(lists()[0], heights);
    layout(lists()[1], heights);
    lists()[0].scrollTop = 0;
    lists()[1].scrollTop = 0;
    intersect(article(lists()[0], '100'));
    intersect(article(lists()[1], '100'));
    view.rerender(tree(['200', '100'], ['200', '100']));
    layout(lists()[0], heights);
    layout(lists()[1], heights);
    flushFrames();
    expect(lists()[0].scrollTop).toBe(0);
    expect(lists()[1].scrollTop).toBe(200);
  });

  it('drops a pending anchor when the timeline source changes before the frame', () => {
    const mounted = mount({ ids: ['100', '90'], anchorSourceKey: 'home:stream' });
    const { view, list, scroller, tree } = mounted;
    const heights = { 100: 200, 90: 200 };

    layout(list, heights);
    scroller.scrollTop = 350;
    intersect(article(list, '90'));
    view.rerender(tree(['100', '90'], { anchorSourceKey: 'local:stream' }));
    layout(view.container.querySelector('.scrollable'), heights);
    heights['100'] = 0;
    flushFrames();
    expect(scroller.scrollTop).toBe(350);
  });

  it('drops a pending anchor when the pane switches between stream and history', () => {
    const mounted = mount({ windowedHistory: false, anchorSourceKey: 'public:stream' });
    const { view, list, scroller, tree } = mounted;
    const heights = { 100: 200, 200: 200 };

    layout(list, heights);
    scroller.scrollTop = 0;
    intersect(article(list, '100'));
    view.rerender(tree(['200', '100'], { windowedHistory: true, anchorSourceKey: 'public:history' }));
    layout(view.container.querySelector('.scrollable'), heights);
    flushFrames();
    expect(scroller.scrollTop).toBe(0);
  });

  it('drops a pending anchor when the reader seeks before the frame', () => {
    const mounted = mount({ ids: ['100', '90'] });
    const { ref, list, scroller } = mounted;
    const heights = { 100: 200, 90: 200 };

    layout(list, heights);
    scroller.scrollTop = 0;
    intersect(article(list, '100'));
    expect(ref.current.filterSurface.snapshot).not.toBeNull();

    const moved = ref.current.scrollToLoadedStatus('90');

    expect(moved.ok).toBe(true);
    expect(ref.current.filterSurface.snapshot).toBeNull();
    expect(ref.current.filterSurface.frame).toBeNull();
    const parked = scroller.scrollTop;

    flushFrames();
    heights['100'] = 400;
    flushFrames();
    expect(scroller.scrollTop).toBe(parked);
  });

  it.each(['wheel', 'touchstart', 'pointerdown', 'keydown'])('drops a pending anchor on %s before the frame', (eventName) => {
    const mounted = mount({ ids: ['100', '90'] });
    const { list, scroller } = mounted;
    const heights = { 100: 200, 90: 200 };

    layout(list, heights);
    scroller.scrollTop = 350;
    intersect(article(list, '90'));
    list.dispatchEvent(new Event(eventName, { bubbles: true }));
    heights['100'] = 0;
    flushFrames();
    expect(scroller.scrollTop).toBe(350);
  });

  it('does not apply the second frame after the reader moves', () => {
    const mounted = mount({ ids: ['100', '90'] });
    const { list, scroller } = mounted;
    const heights = { 100: 200, 90: 200 };

    layout(list, heights);
    scroller.scrollTop = 350;
    intersect(article(list, '90'));
    flushFrames(1);
    scroller.scrollTop = 500;
    heights['100'] = 0;
    flushFrames();
    expect(scroller.scrollTop).toBe(500);
  });

  it('does not apply an anchor after unmount', () => {
    const mounted = mount();
    const { view, list, scroller } = mounted;
    const heights = { 100: 200, 200: 200 };

    layout(list, heights);
    scroller.scrollTop = 0;
    intersect(article(list, '100'));
    view.unmount();
    expect(() => flushFrames()).not.toThrow();
  });

  it('does not let a route change apply an anchor captured on the previous route', () => {
    const history = createMemoryHistory({ initialEntries: ['/public'] });
    const ref = React.createRef();
    const store = reduxStore();
    const view = render(
      <Router history={history}>
        <Provider store={store}>
          <ScrollableList ref={ref} scrollKey='public' trackScroll={false} hasMore={false} filterStatusIds={['100', '200']}>
            {items(['100'])}
          </ScrollableList>
        </Provider>
      </Router>,
    );
    const list = view.container.querySelector('.scrollable');
    const heights = { 100: 200, 200: 200 };

    layout(list, heights);
    list.scrollTop = 0;
    intersect(article(list, '100'));
    expect(ref.current.filterSurface.frame).not.toBeNull();
    act(() => history.push('/home'));
    expect(ref.current.filterSurface.frame).toBeNull();
    view.rerender(
      <Router history={history}>
        <Provider store={store}>
          <ScrollableList ref={ref} scrollKey='public' trackScroll={false} hasMore={false} filterStatusIds={['100', '200']}>
            {items(['200', '100'])}
          </ScrollableList>
        </Provider>
      </Router>,
    );
    layout(view.container.querySelector('.scrollable'), heights);
    flushFrames();
    expect(view.container.querySelector('.scrollable').scrollTop).toBe(0);
  });

  it('keeps the anchor across a modal location that does not change the route session', () => {
    const history = createMemoryHistory({ initialEntries: ['/public'] });
    const ref = React.createRef();
    const store = reduxStore();

    render(
      <Router history={history}>
        <Provider store={store}>
          <ScrollableList ref={ref} scrollKey='public' trackScroll={false} hasMore={false} filterStatusIds={['100']}>
            {items(['100'])}
          </ScrollableList>
        </Provider>
      </Router>,
    );
    const list = document.querySelector('.scrollable');
    const heights = { 100: 200, 90: 200 };

    layout(list, heights);
    list.scrollTop = 350;
    intersect(article(list, '100'));
    const frame = ref.current.filterSurface.frame;

    act(() => history.push('/public', { mastodonModalKey: 'media' }));
    expect(ref.current.filterSurface.frame).toBe(frame);
  });

  it('returns to the latest row on mouse idle and does not let the anchor pin it again', () => {
    const mounted = mount();
    const { view, ref, list, scroller, tree } = mounted;
    const heights = { 100: 200, 200: 200 };

    jest.spyOn(ref.current, 'getScrollHeight').mockImplementation(() => (
      view.container.querySelectorAll('article[data-id]').length * 200
    ));
    layout(list, heights);
    scroller.scrollTop = 0;
    ref.current.handleMouseMove();
    ref.current.handleMouseMove.flush();
    intersect(article(list, '100'));
    view.rerender(tree(['200', '100']));
    layout(view.container.querySelector('.scrollable'), heights);
    expect(scroller.scrollTop).toBe(200);
    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(0);
    flushFrames();
    expect(scroller.scrollTop).toBe(0);
  });

  const mountStatus = (props, ids) => {
    const store = reduxStore();
    const tree = (nextIds, extra = {}) => (
      <Provider store={store}>
        <StatusList
          scrollKey={extra.scrollKey || props.scrollKey}
          timelineId={extra.timelineId || props.timelineId}
          dataTimelineId={extra.dataTimelineId || props.dataTimelineId}
          statusIds={ImmutableList(nextIds)}
          windowedHistory={Object.prototype.hasOwnProperty.call(extra, 'windowedHistory') ? extra.windowedHistory : props.windowedHistory}
          trackScroll={false}
          trackIntersection={false}
          bindToDocument={false}
          filterStatusIds={ImmutableList(['100', '200', '90'])}
        />
      </Provider>
    );
    const view = render(tree(ids));

    return { view, tree, list: () => view.container.querySelector('.scrollable') };
  };

  const trackScroll = (scroller) => {
    let top = scroller.scrollTop || 0;

    Object.defineProperty(scroller, 'scrollTop', {
      configurable: true,
      get: () => top,
      set (value) {
        top = Number(value) || 0;
        scroller.dispatchEvent(new Event('scroll'));
      },
    });
  };

  const openScrollRange = (scroller) => {
    Object.defineProperty(scroller, 'scrollHeight', { configurable: true, get: () => 8000 });
    Object.defineProperty(scroller, 'clientHeight', { configurable: true, get: () => 600 });
  };

  // Hover at the latest row, let the insertion correction move the scroller,
  // then let FilterSurface pin a row that grows above that anchor. The list
  // is not following latest once scrollTop leaves 0, so the pin must apply.
  const growAboveArmedAnchor = (host) => {
    const mounted = mount({ bindToDocument: host === 'document', ids: ['100'] });
    const { view, ref, scroller, tree } = mounted;
    const heights = { 100: 200, 200: 200 };

    openScrollRange(scroller);
    jest.spyOn(ref.current, 'getScrollHeight').mockImplementation(() => (
      view.container.querySelectorAll('article[data-id]').length * 200
    ));
    trackScroll(scroller);
    layout(view.container.querySelector('.scrollable'), heights, { scroller });
    scroller.scrollTop = 0;
    ref.current.handleMouseMove();
    ref.current.handleMouseMove.flush();
    view.rerender(tree(['200', '100']));

    const list = view.container.querySelector('.scrollable');

    layout(list, heights, { scroller });
    ref.current.handleScroll.flush();
    expect(scroller.scrollTop).toBe(200);
    intersect(article(list, '100'));
    heights[200] = 250;
    layout(list, heights, { scroller });
    flushFrames();
    expect(scroller.scrollTop).toBe(250);

    return { ref, scroller };
  };

  it.each(['element', 'document'])('returns to the latest row when a filter correction scroll event arrives before mouse idle on %s', (host) => {
    const { ref, scroller } = growAboveArmedAnchor(host);

    ref.current.handleScroll.flush();
    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(0);
  });

  it.each(['element', 'document'])('returns to the latest row when a filter correction scroll event arrives after mouse idle on %s', (host) => {
    const { ref, scroller } = growAboveArmedAnchor(host);

    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(0);
    ref.current.handleScroll.flush();
    expect(scroller.scrollTop).toBe(0);
  });

  it('does not treat a filter correction as permission to undo a scroll the reader already made', () => {
    const mounted = mount({ ids: ['90', '100'] });
    const { ref, list, scroller } = mounted;
    const heights = { 90: 0, 100: 200 };

    openScrollRange(scroller);
    layout(list, heights);
    scroller.scrollTop = 0;
    ref.current.handleMouseMove();
    ref.current.handleMouseMove.flush();
    scroller.scrollTop = 80;
    intersect(article(list, '100'));
    heights[90] = 50;
    layout(list, heights);
    flushFrames();
    expect(scroller.scrollTop).toBe(130);
    scroller.dispatchEvent(new Event('scroll'));
    ref.current.handleScroll.flush();
    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(130);
  });

  it('does not pin a streaming StatusList and does protect split history at local 0', () => {
    const live = mountStatus({ scrollKey: 'public_timeline-1-live', timelineId: 'public', dataTimelineId: 'public', windowedHistory: false }, ['100']);
    const history = mountStatus({ scrollKey: 'public_timeline-1', timelineId: 'public', dataTimelineId: 'public:split:1', windowedHistory: true }, ['100']);
    const heights = { 100: 200, 200: 200 };

    layout(live.list(), heights);
    layout(history.list(), heights);
    live.list().scrollTop = 0;
    history.list().scrollTop = 0;
    intersect(article(live.list(), '100'));
    intersect(article(history.list(), '100'));
    live.view.rerender(live.tree(['200', '100']));
    history.view.rerender(history.tree(['200', '100']));
    layout(live.list(), heights);
    layout(history.list(), heights);
    flushFrames();
    expect(live.list().scrollTop).toBe(0);
    expect(history.list().scrollTop).toBe(200);
  });
});
