jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
  FormattedMessage: () => null,
  FormattedNumber: () => null,
}));

import { act, fireEvent, render } from '@testing-library/react';
import { Map as ImmutableMap, List as ImmutableList } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { combineReducers } from 'redux-immutable';

jest.mock('../../containers/status_container', () => () => null);
jest.mock('../../containers/scroll_container', () => ({ children }) => children);
jest.mock('../regeneration_indicator', () => () => null);
jest.mock('../load_gap', () => () => null);
jest.mock('../reload_zone', () => () => null);
jest.mock('../load_window_edge', () => () => null);
// Anchor behavior is independent of the translated media controls toolbar.
jest.mock('../media_display_controls', () => () => null);
jest.mock('../../filter_reconciliation/surface', () => ({
  FilterSurface: class {

    update () {}

    destroy () {}

    intersection () {}

    prepare () {}

  },
}));

import ScrollableList from '../scrollable_list';
import StatusList from '../status_list';
import { TIMELINE_ANCHOR_REASONS } from '../../timeline_navigation';

const store = () => createStore(combineReducers({
  dropdown_menu: (state = ImmutableMap()) => state,
  height_cache: (state = ImmutableMap()) => state,
}));

const Row = () => <span className='timeline-anchor-row' />;

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

const layoutArticles = (list, heights, { origin = 0, viewport = 500, scroller = list } = {}) => {
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

      const top = offset - scroller.scrollTop;
      const height = heights[article.getAttribute('data-id')] || 0;

      return rect(top, height);
    };
  });
  list.getBoundingClientRect = () => rect(origin, viewport);
};

describe('ScrollableList timeline anchor', () => {
  let frames;
  let resizeObserverDescriptor;

  beforeEach(() => {
    resizeObserverDescriptor = Object.getOwnPropertyDescriptor(window, 'ResizeObserver');
    frames = [];
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
    if (resizeObserverDescriptor) {
      Object.defineProperty(window, 'ResizeObserver', resizeObserverDescriptor);
    } else {
      delete window.ResizeObserver;
    }
    document.body.innerHTML = '';
    jest.restoreAllMocks();
  });

  const flushFrames = (count = Infinity) => {
    const batch = frames.splice(0, count === Infinity ? frames.length : count);

    act(() => {
      batch.forEach(callback => callback && callback(0));
    });
  };

  const rows = (ids) => ids.map(id => <Row key={id} />);

  it('anchors a visible card instead of using the total scrollHeight delta for a masonry prepend', () => {
    const ref = React.createRef();
    const reduxStore = store();
    const props = {
      ref,
      scrollKey: 'card-feed',
      layoutMode: 'card-3',
      trackScroll: false,
      hasMore: false,
    };
    const view = render(
      <Provider store={reduxStore}>
        <ScrollableList {...props}>{rows(['100', '90'])}</ScrollableList>
      </Provider>,
    );
    const list = view.container.querySelector('.scrollable');
    list.scrollTop = 120;

    const capture = jest.spyOn(ref.current, 'captureVisibleMasonryItem').mockReturnValue({ key: '.$90', top: 80 });
    const restore = jest.spyOn(ref.current, 'restoreMasonryItemAnchor').mockImplementation(() => {});

    view.rerender(
      <Provider store={reduxStore}>
        <ScrollableList {...props}>{rows(['110', '100', '90'])}</ScrollableList>
      </Provider>,
    );

    expect(capture).toHaveBeenCalledTimes(1);
    expect(restore).toHaveBeenCalledWith({ masonryAnchor: true, key: '.$90', top: 80 });
  });

  it('keeps a split reading surface anchored at local zero when a bounded window replaces its oldest item', () => {
    const ref = React.createRef();
    const reduxStore = store();
    const props = {
      ref,
      scrollKey: 'split-history',
      layoutMode: 'card-3',
      readingSurface: true,
      windowedHistory: true,
      trackScroll: false,
      hasMore: false,
    };
    const view = render(
      <Provider store={reduxStore}>
        <ScrollableList {...props}>{rows(['f-pinned', '100', '90'])}</ScrollableList>
      </Provider>,
    );
    const list = view.container.querySelector('.scrollable');
    list.scrollTop = 0;

    const capture = jest.spyOn(ref.current, 'captureVisibleMasonryItem').mockReturnValue({ key: '.$100', top: 60 });
    const restore = jest.spyOn(ref.current, 'restoreMasonryItemAnchor').mockImplementation(() => {});

    // Count and first child key stay the same. The new row is behind
    // the fixed prefix while an old row falls off the bounded window.
    view.rerender(
      <Provider store={reduxStore}>
        <ScrollableList {...props}>{rows(['f-pinned', '110', '100'])}</ScrollableList>
      </Provider>,
    );

    expect(capture).toHaveBeenCalledTimes(1);
    expect(restore).toHaveBeenCalledWith({ masonryAnchor: true, key: '.$100', top: 60 });
  });

  it('selects the visual reading-edge tile, even with nonnumeric media keys and a different DOM order', () => {
    const ref = React.createRef();
    const { container } = render(
      <Provider store={store()}>
        <ScrollableList ref={ref} scrollKey='media' layoutMode='media' trackScroll={false} hasMore={false}>
          {rows(['media:100:0', 'media:100:1', 'media:90:0'])}
        </ScrollableList>
      </Provider>,
    );
    act(() => {
      ref.current.handleMediaShapeChange('original');
    });
    const list = container.querySelector('.scrollable');
    const items = Array.from(container.querySelectorAll('.timeline-masonry__item[data-layout-key]'));
    expect(items).toHaveLength(3);
    Object.defineProperty(list, 'clientHeight', { configurable: true, value: 500 });
    list.getBoundingClientRect = () => rect(0, 500);

    // The first DOM tile is far above the reading edge. The second one
    // covers the edge and must win over the third, which begins below it.
    list.scrollTop = 120;
    const docTops = [-300, 90, 170];
    const tileHeights = [100, 230, 170];
    items.forEach((tile, index) => {
      tile.getBoundingClientRect = () => rect(docTops[index] - list.scrollTop, tileHeights[index]);
    });

    const captured = ref.current.captureVisibleMasonryItem();
    expect(captured).toEqual({ key: items[1].getAttribute('data-layout-key'), top: -30 });
    expect(ref.current.captureVisibleArticle()).toBeNull();

    // A unique tile key restores the correct attachment even if multiple
    // tiles belong to the same status and their keys contain escaped ':'.
    docTops[1] += 60;
    ref.current.restoreMasonryItemAnchor(captured);
    expect(list.scrollTop).toBe(180);
    // Restoration must preserve the selected attachment at its captured
    // screen coordinate. A subsequent *new* capture may select another
    // column's tile if that tile is now closer to the reading edge.
    expect(items[1].getBoundingClientRect().top).toBe(captured.top);
    expect(ref.current.captureVisibleMasonryItem()).toEqual({
      key: items[2].getAttribute('data-layout-key'), top: -10,
    });
  });

  it('corrects a late masonry height measurement for two frames but cancels on user intent', () => {
    const ref = React.createRef();
    const { container } = render(
      <Provider store={store()}>
        <ScrollableList ref={ref} scrollKey='media' layoutMode='media' trackScroll={false} hasMore={false}>
          {rows(['media:100:0'])}
        </ScrollableList>
      </Provider>,
    );
    act(() => {
      ref.current.handleMediaShapeChange('original');
    });
    const list = container.querySelector('.scrollable');
    const tile = container.querySelector('.timeline-masonry__item');
    Object.defineProperty(list, 'clientHeight', { configurable: true, value: 500 });
    list.getBoundingClientRect = () => rect(0, 500);

    let docTop = 100;
    list.scrollTop = 120;
    tile.getBoundingClientRect = () => rect(docTop - list.scrollTop, 240);
    const anchor = ref.current.captureVisibleMasonryItem();
    expect(anchor).toEqual({ key: tile.getAttribute('data-layout-key'), top: -20 });

    ref.current._scheduleMasonryAnchorCorrection(anchor);
    docTop += 50;
    flushFrames(1);
    expect(list.scrollTop).toBe(170);

    fireEvent.wheel(list, { deltaY: 20 });
    docTop += 30;
    flushFrames();
    expect(list.scrollTop).toBe(170);
  });

  it('preserves the reading tile when a new post gains its real height after two frames', () => {
    Object.defineProperty(window, 'ResizeObserver', { configurable: true, value: undefined });

    const heights = {
      '110': 100, '100': 100, '90': 100, '80': 100, '70': 100,
      '60': 100, '50': 100, '40': 100, '30': 100, '20': 100,
    };

    // Unlike mocked handler tests, this measures the actual Masonry layout
    // and scrollTop as its height state changes in a later React commit.
    jest.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function () {
      if (this.classList.contains('scrollable')) {
        return rect(0, 240);
      }
      if (this.classList.contains('timeline-masonry')) {
        return { ...rect(0, 0), width: 590, right: 590 };
      }
      if (this.classList.contains('timeline-masonry__item')) {
        const match = this.style.transform.match(/translate3d\\(0, ([\\d.]+)px, 0\\)/);
        const y = match ? Number(match[1]) : 0;
        const scroller = this.closest('.scrollable');
        const id = this.querySelector('article[data-id]')?.getAttribute('data-id');
        return rect(y - (scroller?.scrollTop || 0), heights[id] || 100);
      }
      return rect(0, 0);
    });

    const ref = React.createRef();
    const reduxStore = store();
    const props = { ref, scrollKey: 'late-media-height', layoutMode: 'card-3', trackScroll: false, hasMore: false };
    const original = ['100', '90', '80', '70', '60', '50', '40', '30', '20'];
    const view = render(
      <Provider store={reduxStore}>
        <ScrollableList {...props}>{rows(original)}</ScrollableList>
      </Provider>,
    );
    const list = view.container.querySelector('.scrollable');
    Object.defineProperty(list, 'clientHeight', { configurable: true, value: 240 });
    list.scrollTop = 150;

    const before = ref.current.captureVisibleMasonryItem();
    expect(before).not.toBeNull();

    view.rerender(
      <Provider store={reduxStore}>
        <ScrollableList {...props}>{rows(['110', ...original])}</ScrollableList>
      </Provider>,
    );
    flushFrames();
    flushFrames();

    const stable = ref.current.captureVisibleMasonryItem();
    expect(stable).not.toBeNull();
    const target = Array.from(view.container.querySelectorAll('.timeline-masonry__item'))
      .find(node => node.getAttribute('data-layout-key') === before.key);
    expect(target).toBeDefined();
    expect(target.getBoundingClientRect().top).toBe(before.top);
    const settledScrollTop = list.scrollTop;

    // The network image arrives after the original two correction frames.
    // Its measured height grows by 300px, shifting all original columns.
    heights['110'] = 400;
    act(() => {
      window.dispatchEvent(new Event('resize'));
    });
    expect(list.scrollTop).toBe(settledScrollTop + 300);
    expect(target.getBoundingClientRect().top).toBe(before.top);

    flushFrames();
    flushFrames();
    expect(target.getBoundingClientRect().top).toBe(before.top);

    // Following the live feed's absolute top is a different mode: do not
    // pin the old card against the reader when the image height changes.
    list.scrollTop = 0;
    heights['110'] = 450;
    act(() => {
      window.dispatchEvent(new Event('resize'));
    });
    expect(list.scrollTop).toBe(0);

  });

  it('scrolls one inner list to a loaded id and leaves the sibling list alone', () => {
    const left = React.createRef();
    const right = React.createRef();
    const onLoadMore = jest.fn();
    const { container } = render(
      <Provider store={store()}>
        <div>
          <ScrollableList ref={left} scrollKey='column-a' trackScroll={false} onLoadMore={onLoadMore} hasMore>
            {rows(['100', '90', '80'])}
          </ScrollableList>
          <ScrollableList ref={right} scrollKey='column-b' trackScroll={false} hasMore={false}>
            {rows(['100', '90', '80'])}
          </ScrollableList>
        </div>
      </Provider>,
    );
    const lists = container.querySelectorAll('.scrollable');
    const heights = { 100: 100, 90: 100, 80: 140 };

    layoutArticles(lists[0], heights, { origin: 0 });
    layoutArticles(lists[1], heights, { origin: 40 });

    const loadsBeforeScroll = onLoadMore.mock.calls.length;
    const moved = right.current.scrollToLoadedStatus('80', { alignment: 'top' });

    expect(moved.ok).toBe(true);
    expect(moved.anchor.statusId).toBe('80');
    expect(lists[1].scrollTop).toBe(200);
    expect(lists[0].scrollTop).toBe(0);
    expect(onLoadMore.mock.calls.length).toBe(loadsBeforeScroll);
    expect(left.current.getTimelineScrollHost().kind).toBe('pane');
    expect(left.current.getTimelineScrollHost().list).toBe(lists[0]);
  });

  it('corrects for a height change on the next frames and stops after the row disappears', () => {
    const ref = React.createRef();
    const { container } = render(
      <Provider store={store()}>
        <ScrollableList ref={ref} scrollKey='home' trackScroll={false} hasMore={false}>
          {rows(['100', '90', '80'])}
        </ScrollableList>
      </Provider>,
    );
    const list = container.querySelector('.scrollable');
    const heights = { 100: 100, 90: 100, 80: 100 };

    layoutArticles(list, heights);
    ref.current.scrollToLoadedStatus('90');
    expect(list.scrollTop).toBe(100);
    heights['100'] = 180;
    flushFrames(1);
    expect(list.scrollTop).toBe(180);

    list.querySelector('article[data-id="90"]').remove();
    flushFrames(1);
    expect(list.scrollTop).toBe(180);
  });

  it('drops a queued correction on user scroll, a newer jump, unmount, and scrollKey change', () => {
    const ref = React.createRef();
    const view = render(
      <Provider store={store()}>
        <ScrollableList ref={ref} scrollKey='route-a' trackScroll={false} hasMore={false}>
          {rows(['100', '90', '80'])}
        </ScrollableList>
      </Provider>,
    );
    const list = view.container.querySelector('.scrollable');
    const heights = { 100: 100, 90: 120, 80: 100 };

    layoutArticles(list, heights);
    ref.current.scrollToLoadedStatus('80');
    expect(list.scrollTop).toBe(220);
    list.scrollTop = 40;
    fireEvent.scroll(list);
    flushFrames();
    expect(list.scrollTop).toBe(40);

    ref.current.scrollToLoadedStatus('90');
    const queued = frames.length;
    ref.current.scrollToLoadedStatus('100');
    expect(queued).toBeGreaterThan(0);
    flushFrames();
    expect(list.scrollTop).toBe(0);

    heights['100'] = 50;
    ref.current.scrollToLoadedStatus('80');
    view.rerender(
      <Provider store={store()}>
        <ScrollableList ref={ref} scrollKey='route-b' trackScroll={false} hasMore={false}>
          {rows(['100', '90', '80'])}
        </ScrollableList>
      </Provider>,
    );
    const afterKeyChange = list.scrollTop;
    flushFrames();
    expect(list.scrollTop).toBe(afterKeyChange);

    ref.current.scrollToLoadedStatus('90');
    view.unmount();
    expect(() => flushFrames()).not.toThrow();
  });

  it('does not let an armed mouse-idle snap pull an anchor jump back to the top', () => {
    const ref = React.createRef();
    const { container } = render(
      <Provider store={store()}>
        <ScrollableList ref={ref} scrollKey='home' trackScroll={false} hasMore={false}>
          {rows(['100', '90'])}
        </ScrollableList>
      </Provider>,
    );
    const list = container.querySelector('.scrollable');

    layoutArticles(list, { 100: 180, 90: 180 });
    list.scrollTop = 0;
    ref.current.handleMouseMove();
    ref.current.handleMouseMove.flush();
    expect(ref.current.scrollToTopOnMouseIdle).toBe(true);

    const moved = ref.current.scrollToLoadedStatus('90');

    expect(moved.ok).toBe(true);
    ref.current.handleMouseIdle();
    expect(list.scrollTop).toBe(180);
    expect(ref.current.scrollToLoadedStatus('70')).toEqual({ ok: false, reason: TIMELINE_ANCHOR_REASONS.NOT_LOADED });
    expect(list.scrollTop).toBe(180);
  });

  it('does not snap a scrollbar move back to the top on mouse idle', () => {
    const ref = React.createRef();
    const { container } = render(
      <Provider store={store()}>
        <ScrollableList ref={ref} scrollKey='home' trackScroll={false} hasMore={false}>
          {rows(['100', '90'])}
        </ScrollableList>
      </Provider>,
    );
    const list = container.querySelector('.scrollable');

    layoutArticles(list, { 100: 180, 90: 180 });
    list.scrollTop = 0;
    ref.current.handleMouseMove();
    ref.current.handleMouseMove.flush();
    expect(ref.current.scrollToTopOnMouseIdle).toBe(true);
    list.scrollTop = 420;
    ref.current.handleMouseIdle();
    expect(list.scrollTop).toBe(420);
  });

  it('treats a jump scroll event as synthetic so it does not load more or cancel correction', () => {
    const ref = React.createRef();
    const onLoadMore = jest.fn();
    const { container } = render(
      <Provider store={store()}>
        <ScrollableList ref={ref} scrollKey='home' trackScroll={false} onLoadMore={onLoadMore} hasMore>
          {rows(['100', '90', '80'])}
        </ScrollableList>
      </Provider>,
    );
    const list = container.querySelector('.scrollable');
    let top = 0;

    Object.defineProperty(list, 'scrollTop', {
      configurable: true,
      get: () => top,
      set (value) {
        top = Number(value) || 0;
        list.dispatchEvent(new Event('scroll'));
      },
    });
    Object.defineProperty(list, 'scrollHeight', {
      configurable: true,
      get: () => 4000,
    });
    Object.defineProperty(list, 'clientHeight', {
      configurable: true,
      get: () => 600,
    });

    const heights = { 100: 100, 90: 100, 80: 100 };

    layoutArticles(list, heights);

    const loadsBeforeScroll = onLoadMore.mock.calls.length;

    ref.current.scrollToLoadedStatus('90');
    ref.current.handleScroll.flush();
    expect(list.scrollTop).toBe(100);
    expect(onLoadMore.mock.calls.length).toBe(loadsBeforeScroll);

    heights['100'] = 180;
    flushFrames(1);
    ref.current.handleScroll.flush();
    expect(list.scrollTop).toBe(180);

    heights['100'] = 240;
    flushFrames(1);
    ref.current.handleScroll.flush();
    expect(list.scrollTop).toBe(240);
    expect(onLoadMore.mock.calls.length).toBe(loadsBeforeScroll);

    heights['100'] = 100;
    ref.current.scrollToLoadedStatus('80');
    expect(list.scrollTop).toBe(200);
    heights['100'] = 180;
    list.scrollTop = 40;
    ref.current.handleScroll.flush();
    flushFrames();
    expect(list.scrollTop).toBe(40);
    expect(onLoadMore.mock.calls.length).toBe(loadsBeforeScroll);
  });

  it('does not page when an anchor jump or its correction lands near the end', () => {
    const ref = React.createRef();
    const onLoadMore = jest.fn();
    const { container } = render(
      <Provider store={store()}>
        <ScrollableList ref={ref} scrollKey='home' trackScroll={false} onLoadMore={onLoadMore} hasMore>
          {rows(['100', '90', '80'])}
        </ScrollableList>
      </Provider>,
    );
    const list = container.querySelector('.scrollable');
    let top = 0;

    Object.defineProperty(list, 'scrollTop', {
      configurable: true,
      get: () => top,
      set (value) {
        top = Number(value) || 0;
        list.dispatchEvent(new Event('scroll'));
      },
    });
    Object.defineProperty(list, 'scrollHeight', {
      configurable: true,
      get: () => 900,
    });
    Object.defineProperty(list, 'clientHeight', {
      configurable: true,
      get: () => 300,
    });

    const heights = { 100: 200, 90: 200, 80: 200 };

    layoutArticles(list, heights);

    const loadsBeforeUser = onLoadMore.mock.calls.length;

    ref.current.setScrollTop(500);
    ref.current.handleScroll.flush();
    expect(list.scrollTop).toBe(500);
    expect(onLoadMore.mock.calls.length).toBe(loadsBeforeUser + 1);

    const loadsBeforeJump = onLoadMore.mock.calls.length;
    const moved = ref.current.scrollToLoadedStatus('80');

    ref.current.handleScroll.flush();
    expect(moved.ok).toBe(true);
    expect(list.scrollTop).toBe(400);
    expect(onLoadMore.mock.calls.length).toBe(loadsBeforeJump);

    heights['100'] = 320;
    flushFrames(1);
    ref.current.handleScroll.flush();
    expect(list.scrollTop).toBe(520);

    heights['100'] = 360;
    flushFrames(1);
    ref.current.handleScroll.flush();
    expect(list.scrollTop).toBe(560);
    expect(onLoadMore.mock.calls.length).toBe(loadsBeforeJump);

    heights['100'] = 200;
    ref.current.scrollToLoadedStatus('80');
    expect(list.scrollTop).toBe(400);
    list.scrollTop = 590;
    ref.current.handleScroll.flush();
    flushFrames();
    expect(list.scrollTop).toBe(590);
    expect(onLoadMore.mock.calls.length).toBe(loadsBeforeJump + 1);
  });

  it('does not auto-load the same older cursor while a partial page is paused', () => {
    const ref = React.createRef();
    const onLoadMore = jest.fn();
    const { container } = render(
      <Provider store={store()}>
        <ScrollableList ref={ref} scrollKey='history' trackScroll={false} onLoadMore={onLoadMore} hasMore={false} olderStatus='paused'>
          {rows(['100', '90', '80'])}
        </ScrollableList>
      </Provider>,
    );
    const list = container.querySelector('.scrollable');
    let top = 0;

    Object.defineProperty(list, 'scrollTop', {
      configurable: true,
      get: () => top,
      set (value) {
        top = Number(value) || 0;
      },
    });
    Object.defineProperty(list, 'scrollHeight', { configurable: true, get: () => 900 });
    Object.defineProperty(list, 'clientHeight', { configurable: true, get: () => 300 });

    ref.current.setScrollTop(500);
    ref.current.handleScroll.flush();

    expect(onLoadMore).not.toHaveBeenCalled();
  });

  it('scrolls the document host under the sticky header and not an inner list', () => {
    const portal = document.createElement('div');
    portal.id = 'tabs-bar__portal';
    const wrapper = document.createElement('div');
    wrapper.className = 'tabs-bar__wrapper';
    wrapper.getBoundingClientRect = () => rect(0, 64);
    wrapper.appendChild(portal);
    document.body.appendChild(wrapper);

    const ref = React.createRef();
    const { container } = render(
      <Provider store={store()}>
        <ScrollableList ref={ref} scrollKey='single' trackScroll={false} bindToDocument hasMore={false}>
          {rows(['100', '90', '80'])}
        </ScrollableList>
      </Provider>,
    );
    const list = container.querySelector('.scrollable');
    const scroller = document.scrollingElement || document.body;

    layoutArticles(list, { 100: 100, 90: 100, 80: 100 }, { origin: 0, scroller });
    scroller.scrollTop = 0;

    const moved = ref.current.scrollToLoadedStatus('90');

    expect(moved.ok).toBe(true);
    expect(ref.current.getTimelineScrollHost().kind).toBe('document');
    expect(scroller.scrollTop).toBe(36);
    expect(list.scrollTop).toBe(0);
  });

  it('keeps the visible article when a late row is inserted below or above it', () => {
    const heights = { 900: 400, 500: 1100, 300: 200, 250: 250, 400: 250 };
    const original = HTMLElement.prototype.getBoundingClientRect;

    HTMLElement.prototype.getBoundingClientRect = function () {
      if (this.classList && this.classList.contains('scrollable')) {
        return rect(0, 600);
      }

      const id = this.getAttribute && this.getAttribute('data-id');

      if (!id || heights[id] === undefined) {
        return original.call(this);
      }

      const list = this.closest('.scrollable');
      const articles = Array.from(list.querySelectorAll('article[data-id]'));
      let offset = 0;

      articles.some(article => {
        if (article === this) {
          return true;
        }

        offset += heights[article.getAttribute('data-id')] || 0;

        return false;
      });

      return rect(offset - (list.scrollTop || 0), heights[id]);
    };

    const view = render(
      <Provider store={store()}>
        <ScrollableList scrollKey='home' trackScroll={false} hasMore={false}>
          {rows(['500', '300'])}
        </ScrollableList>
      </Provider>,
    );
    const list = view.container.querySelector('.scrollable');

    list.scrollTop = 200;
    view.rerender(
      <Provider store={store()}>
        <ScrollableList scrollKey='home' trackScroll={false} hasMore={false}>
          {rows(['500', '250', '300'])}
        </ScrollableList>
      </Provider>,
    );

    expect(list.scrollTop).toBe(200);

    view.rerender(
      <Provider store={store()}>
        <ScrollableList scrollKey='home' trackScroll={false} hasMore={false}>
          {rows(['900', '500', '300'])}
        </ScrollableList>
      </Provider>,
    );
    list.scrollTop = 500;
    view.rerender(
      <Provider store={store()}>
        <ScrollableList scrollKey='home' trackScroll={false} hasMore={false}>
          {rows(['900', '400', '500', '300'])}
        </ScrollableList>
      </Provider>,
    );

    expect(list.scrollTop).toBe(750);
    HTMLElement.prototype.getBoundingClientRect = original;
  });

  it('anchors the article below a sticky header instead of the one the header covers', () => {
    const heights = { 40: 40, 500: 500, 80: 100 };
    const original = HTMLElement.prototype.getBoundingClientRect;

    HTMLElement.prototype.getBoundingClientRect = function () {
      if (this.classList && this.classList.contains('tabs-bar__wrapper')) {
        return rect(0, 48);
      }

      if (this.classList && this.classList.contains('scrollable')) {
        return rect(0, 600);
      }

      const id = this.getAttribute && this.getAttribute('data-id');

      if (!id || heights[id] === undefined) {
        return original.call(this);
      }

      const scroller = document.scrollingElement || document.body;
      const list = this.closest('.scrollable');
      const articles = Array.from(list.querySelectorAll('article[data-id]'));
      let offset = 0;

      articles.some(article => {
        if (article === this) {
          return true;
        }

        offset += heights[article.getAttribute('data-id')] || 0;

        return false;
      });

      return rect(offset - (scroller.scrollTop || 0), heights[id]);
    };

    const portal = document.createElement('div');
    portal.id = 'tabs-bar__portal';
    const wrapper = document.createElement('div');
    wrapper.className = 'tabs-bar__wrapper';
    wrapper.appendChild(portal);
    document.body.appendChild(wrapper);

    const view = render(
      <Provider store={store()}>
        <ScrollableList scrollKey='home' trackScroll={false} bindToDocument hasMore={false}>
          {rows(['40', '500'])}
        </ScrollableList>
      </Provider>,
    );
    const scroller = document.scrollingElement || document.body;

    scroller.scrollTop = 10;
    view.rerender(
      <Provider store={store()}>
        <ScrollableList scrollKey='home' trackScroll={false} bindToDocument hasMore={false}>
          {rows(['40', '80', '500'])}
        </ScrollableList>
      </Provider>,
    );

    expect(scroller.scrollTop).toBe(110);
    HTMLElement.prototype.getBoundingClientRect = original;
  });
});

describe('StatusList timeline anchor', () => {
  beforeEach(() => {
    global.IntersectionObserver = class {

      observe () {}

      unobserve () {}

      disconnect () {}

    };
    jest.spyOn(window, 'requestAnimationFrame').mockImplementation(() => 1);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('forwards scrollToLoadedStatus to one status list host', () => {
    const first = React.createRef();
    const second = React.createRef();
    const ids = ImmutableList(['101', '102']);
    const { container } = render(
      <Provider store={store()}>
        <div>
          <StatusList ref={first} scrollKey='live' timelineId='home' statusIds={ids} trackScroll={false} trackIntersection={false} />
          <StatusList ref={second} scrollKey='history' timelineId='home' statusIds={ids} trackScroll={false} trackIntersection={false} />
        </div>
      </Provider>,
    );
    const lists = container.querySelectorAll('.scrollable');

    layoutArticles(lists[0], { 101: 100, 102: 100 }, { origin: 10 });
    layoutArticles(lists[1], { 101: 100, 102: 100 }, { origin: 400 });

    const moved = second.current.scrollToLoadedStatus('102');

    expect(moved.ok).toBe(true);
    expect(moved.anchor.statusId).toBe('102');
    expect(lists[1].scrollTop).toBe(100);
    expect(lists[0].scrollTop).toBe(0);
    expect(first.current.captureReadingAnchor().displayRowId).toBe('101');
  });
});
