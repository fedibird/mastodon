/* eslint-disable react/prop-types, react/jsx-no-bind */
jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('../../containers/status_container', () => () => null);
jest.mock('../../containers/scroll_container', () => ({ children }) => children);
jest.mock('../regeneration_indicator', () => () => null);
jest.mock('../load_gap', () => () => null);
jest.mock('../reload_zone', () => () => null);
jest.mock('../load_window_edge', () => () => null);

import { act, fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider, connect } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { changeSetting } from '../../actions/settings';
import { restoreFilterAnchor } from '../../filter_reconciliation/scroll_anchor';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import settings from '../../reducers/settings';
import timelines from '../../reducers/timelines';
import StatusTimelineSplitController from '../../features/ui/components/status_timeline_split_controller';
import LegacyColumn from '../../features/ui/components/column';
import { isProgrammaticTopScroll, scrollTop } from '../../scroll';
import ScrollableList from '../scrollable_list';

const scrollTopOwner = () => {
  let proto = Element.prototype;

  while (proto) {
    if (Object.getOwnPropertyDescriptor(proto, 'scrollTop')) {
      return proto;
    }

    proto = Object.getPrototypeOf(proto);
  }

  return null;
};

const nativeScrollTop = Object.getOwnPropertyDescriptor(scrollTopOwner(), 'scrollTop');

const store = () => createStore(combineReducers({
  dropdown_menu: (state = ImmutableMap()) => state,
}));

const Row = ({ id }) => <span data-row={id} />;

describe('header smooth scroll', () => {
  let frames;
  let writes;
  let tracked;
  const originalMatchMedia = window.matchMedia;

  const flushFrames = (times = 1) => {
    for (let i = 0; i < times; i += 1) {
      const batch = frames.splice(0, frames.length);

      act(() => {
        batch.forEach(callback => callback && callback(0));
      });

      if (frames.length === 0) {
        break;
      }
    }
  };

  const installSmoothScroll = (element) => {
    tracked = element;
    writes = 0;
    let expected = nativeScrollTop.get.call(element);
    let sawProgrammatic = false;
    let alive = false;

    element.scrollTo = (options = {}) => {
      const top = options.top || 0;

      if (options.behavior !== 'smooth') {
        nativeScrollTop.set.call(element, top);
        return;
      }

      const start = nativeScrollTop.get.call(element);
      let ticks = 0;

      alive = true;
      expected = start;
      sawProgrammatic = isProgrammaticTopScroll(element);

      const step = () => {
        if (!alive) {
          return;
        }

        const programmatic = isProgrammaticTopScroll(element);

        if (programmatic) {
          sawProgrammatic = true;
        }

        const actual = nativeScrollTop.get.call(element);
        const moved = Math.abs(actual - expected) > 0.5;
        const released = sawProgrammatic && !programmatic;

        // Chrome aborts the running animation on any scrollTop assignment,
        // even when the assigned value equals the current offset.
        if (moved || writes > 0 || released) {
          alive = false;
          return;
        }

        ticks += 1;
        const next = ticks >= 4 ? top : start + ((top - start) * ticks / 4);

        nativeScrollTop.set.call(element, next);
        expected = nativeScrollTop.get.call(element);
        element.dispatchEvent(new Event('scroll'));

        if (next !== top) {
          requestAnimationFrame(step);
        }
      };

      requestAnimationFrame(step);
    };

    return {
      get alive () {
        return alive;
      },
    };
  };

  beforeEach(() => {
    frames = [];
    writes = 0;
    tracked = null;
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
    const owner = scrollTopOwner();
    const current = Object.getOwnPropertyDescriptor(owner, 'scrollTop');

    Object.defineProperty(owner, 'scrollTop', {
      configurable: true,
      enumerable: current.enumerable,
      get: current.get,
      set (value) {
        if (tracked && this === tracked) {
          writes += 1;
        }

        return nativeScrollTop.set.call(this, value);
      },
    });
  });

  afterEach(() => {
    const node = document.scrollingElement || document.documentElement;

    if (isProgrammaticTopScroll(node)) {
      node.dispatchEvent(new Event('wheel', { bubbles: true }));
    }

    document.body.innerHTML = '';
    const owner = scrollTopOwner();

    Object.defineProperty(owner, 'scrollTop', nativeScrollTop);
    window.matchMedia = originalMatchMedia;
    jest.restoreAllMocks();
  });

  const layout = (list) => {
    list.getBoundingClientRect = () => ({ top: 0, bottom: 600, left: 0, right: 320, width: 320, height: 600 });
    list.querySelectorAll('article[data-id]').forEach((article, index) => {
      article.getBoundingClientRect = () => {
        const top = (index * 200) - nativeScrollTop.get.call(list);

        return { top, bottom: top + 180, left: 0, right: 320, width: 320, height: 180 };
      };
    });
  };

  it('reaches zero after a filter restore and a height write, without a user-scroll signal', () => {
    const onUserScroll = jest.fn();
    const onLoadMore = jest.fn();
    const onScrollToTop = jest.fn();
    const listRef = React.createRef();
    const { container } = render(
      <Provider store={store()}>
        <ScrollableList ref={listRef} scrollKey='home' trackScroll={false} hasMore onLoadMore={onLoadMore} onUserScroll={onUserScroll} onScrollToTop={onScrollToTop}>
          <Row key='100' id='100' />
          <Row key='90' id='90' />
          <Row key='80' id='80' />
        </ScrollableList>
      </Provider>,
    );
    const list = container.querySelector('.scrollable');
    let scrollHeight = 4300;

    Object.defineProperty(list, 'scrollHeight', { configurable: true, get: () => scrollHeight });
    Object.defineProperty(list, 'clientHeight', { configurable: true, get: () => 600 });
    nativeScrollTop.set.call(list, 4000);
    layout(list);
    onLoadMore.mockClear();
    onUserScroll.mockClear();
    const animation = installSmoothScroll(list);

    scrollTop(list);
    flushFrames(1);
    expect(nativeScrollTop.get.call(list)).toBeLessThan(4000);
    expect(nativeScrollTop.get.call(list)).toBeGreaterThan(0);

    const anchor = {
      offset: nativeScrollTop.get.call(list),
      rows: [],
      focused: null,
    };

    restoreFilterAnchor(anchor, list, list, 0);
    listRef.current.setScrollTop(2500);
    scrollHeight = 5100;
    listRef.current.setScrollTop(scrollHeight - 4000);
    fireEvent.scroll(list);
    listRef.current.handleScroll.flush();

    expect(onUserScroll).not.toHaveBeenCalled();
    expect(onLoadMore).not.toHaveBeenCalled();
    flushFrames(8);
    listRef.current.handleScroll.flush();

    expect(animation.alive || nativeScrollTop.get.call(list) === 0).toBe(true);
    expect(nativeScrollTop.get.call(list)).toBe(0);
    expect(writes).toBe(0);
    expect(onUserScroll).not.toHaveBeenCalled();
    expect(onScrollToTop).toHaveBeenCalled();
    expect(isProgrammaticTopScroll(list)).toBe(false);
  });

  it('lets a wheel, key, or drag interrupt and then accept a new scroll position', () => {
    const onUserScroll = jest.fn();
    const column = React.createRef();
    const listRef = React.createRef();
    const view = render(
      <Provider store={store()}>
        <Column ref={column} label='Home'>
          <ScrollableList ref={listRef} scrollKey='home' trackScroll={false} hasMore={false} onUserScroll={onUserScroll}>
            <Row key='100' id='100' />
          </ScrollableList>
        </Column>
      </Provider>,
    );
    const list = view.container.querySelector('.scrollable');

    nativeScrollTop.set.call(list, 4000);
    installSmoothScroll(list);
    column.current.scrollTop();
    flushFrames(1);
    const mid = nativeScrollTop.get.call(list);

    fireEvent.wheel(list);
    fireEvent.scroll(list);
    listRef.current.handleScroll.flush();
    flushFrames(8);

    expect(mid).toBeGreaterThan(0);
    expect(nativeScrollTop.get.call(list)).toBe(mid);
    expect(onUserScroll).toHaveBeenCalled();
    expect(isProgrammaticTopScroll(list)).toBe(false);
    list.scrollTop = mid - 40;
    expect(nativeScrollTop.get.call(list)).toBe(mid - 40);

    nativeScrollTop.set.call(list, 4000);
    writes = 0;
    installSmoothScroll(list);
    column.current.scrollTop();
    flushFrames(1);
    fireEvent.keyDown(list, { key: 'ArrowDown' });
    flushFrames(6);
    expect(isProgrammaticTopScroll(list)).toBe(false);
    expect(nativeScrollTop.get.call(list)).toBeGreaterThan(0);

    nativeScrollTop.set.call(list, 4000);
    writes = 0;
    installSmoothScroll(list);
    column.current.scrollTop();
    flushFrames(1);
    fireEvent.pointerMove(list, { buttons: 1, pointerType: 'mouse' });
    flushFrames(6);
    expect(isProgrammaticTopScroll(list)).toBe(false);
    view.unmount();
  });

  it('drops the session on unmount and when the scroller leaves the document', () => {
    const ref = React.createRef();
    const view = render(
      <Column ref={ref} bindToDocument label='Home'>
        <div className='scrollable' />
      </Column>,
    );
    const scroller = document.scrollingElement || document.documentElement;

    nativeScrollTop.set.call(scroller, 3000);
    installSmoothScroll(scroller);
    ref.current.scrollTop();
    flushFrames(1);
    const mid = nativeScrollTop.get.call(scroller);

    view.unmount();
    flushFrames(8);

    expect(isProgrammaticTopScroll(scroller)).toBe(false);
    expect(nativeScrollTop.get.call(scroller)).toBe(mid);
    nativeScrollTop.set.call(scroller, 0);

    const pane = render(
      <Column label='Notifications'>
        <div className='scrollable' />
      </Column>,
    );
    const list = pane.container.querySelector('.scrollable');

    nativeScrollTop.set.call(list, 2200);
    writes = 0;
    installSmoothScroll(list);
    scrollTop(list);
    flushFrames(1);
    expect(isProgrammaticTopScroll(list)).toBe(true);
    list.remove();
    flushFrames(4);
    expect(isProgrammaticTopScroll(list)).toBe(false);
    pane.unmount();
  });

  it('scrolls only the targeted pane and leaves the sibling column where it was', () => {
    const left = React.createRef();
    const right = React.createRef();
    const { container } = render(
      <Provider store={store()}>
        <div>
          <Column ref={left} label='Home'>
            <ScrollableList ref={React.createRef()} scrollKey='home' trackScroll={false} hasMore={false}>
              <Row key='100' id='100' />
            </ScrollableList>
          </Column>
          <Column ref={right} label='Local'>
            <ScrollableList scrollKey='local' trackScroll={false} hasMore={false}>
              <Row key='100' id='100' />
            </ScrollableList>
          </Column>
        </div>
      </Provider>,
    );
    const lists = container.querySelectorAll('.scrollable');

    nativeScrollTop.set.call(lists[0], 3600);
    nativeScrollTop.set.call(lists[1], 880);
    installSmoothScroll(lists[0]);
    left.current.scrollTop();
    lists[1].scrollTop = 880;
    restoreFilterAnchor({ offset: 880, rows: [], focused: null }, lists[1], lists[1], 0);
    flushFrames(8);

    expect(nativeScrollTop.get.call(lists[0])).toBe(0);
    expect(nativeScrollTop.get.call(lists[1])).toBe(880);
    expect(isProgrammaticTopScroll(lists[1])).toBe(false);
  });

  it('jumps immediately when reduced motion is requested', () => {
    window.matchMedia = () => ({ matches: true, addListener () {}, removeListener () {} });
    const node = document.createElement('div');

    document.body.appendChild(node);
    nativeScrollTop.set.call(node, 640);
    node.scrollTo = jest.fn();
    scrollTop(node);
    expect(node.scrollTo).not.toHaveBeenCalled();
    expect(nativeScrollTop.get.call(node)).toBe(0);
    expect(isProgrammaticTopScroll(node)).toBe(false);
  });

  it('does not let the legacy column debounce cancel a scroll the inner list started', () => {
    const ref = React.createRef();
    const { container } = render(
      <LegacyColumn ref={ref} heading='notifications'>
        <div className='scrollable' />
      </LegacyColumn>,
    );
    const list = container.querySelector('.scrollable');

    nativeScrollTop.set.call(list, 2400);
    installSmoothScroll(list);
    fireEvent.click(screen.getByText('notifications'));
    flushFrames(1);
    list.dispatchEvent(new Event('scroll'));
    ref.current.handleScroll();
    ref.current.handleScroll.flush();
    flushFrames(8);
    expect(nativeScrollTop.get.call(list)).toBe(0);
    expect(isProgrammaticTopScroll(list)).toBe(false);

    nativeScrollTop.set.call(list, 500);
    writes = 0;
    ref.current.handleScroll();
    ref.current.handleScroll.flush();
    ref.current.handleScroll.flush();
    expect(writes).toBe(0);
    expect(nativeScrollTop.get.call(list)).toBe(500);
  });

  it('does not assign scrollTop when wheels follow a finished header scroll', () => {
    const column = React.createRef();
    const view = render(
      <Column ref={column} label='Home'>
        <div className='scrollable' />
      </Column>,
    );
    const list = view.container.querySelector('.scrollable');

    nativeScrollTop.set.call(list, 2400);
    installSmoothScroll(list);
    column.current.scrollTop();
    flushFrames(8);
    expect(nativeScrollTop.get.call(list)).toBe(0);
    expect(isProgrammaticTopScroll(list)).toBe(false);

    nativeScrollTop.set.call(list, 500);
    writes = 0;
    column.current.handleWheel();
    column.current.handleWheel();
    column.current.handleWheel();
    list.dispatchEvent(new WheelEvent('wheel', { bubbles: true, cancelable: true }));
    view.unmount();

    expect(writes).toBe(0);
    expect(nativeScrollTop.get.call(list)).toBe(500);
  });

  it('ignores a cancel closure once its session has been replaced', () => {
    const node = document.createElement('div');

    document.body.appendChild(node);
    nativeScrollTop.set.call(node, 2200);
    installSmoothScroll(node);
    const first = scrollTop(node);

    flushFrames(1);
    const second = scrollTop(node);
    const top = nativeScrollTop.get.call(node);

    writes = 0;
    first();
    expect(isProgrammaticTopScroll(node)).toBe(true);
    expect(writes).toBe(0);
    expect(nativeScrollTop.get.call(node)).toBe(top);
    second();
    expect(isProgrammaticTopScroll(node)).toBe(false);
    const pinnedWrites = writes;

    first();
    second();
    expect(writes).toBe(pinnedWrites);
    expect(nativeScrollTop.get.call(node)).toBe(top);
  });

  it('lets an explicit seek replace an in-progress header scroll', () => {
    const listRef = React.createRef();
    const { container } = render(
      <Provider store={store()}>
        <ScrollableList ref={listRef} scrollKey='home' trackScroll={false} hasMore={false}>
          <Row key='100' id='100' />
          <Row key='90' id='90' />
          <Row key='80' id='80' />
        </ScrollableList>
      </Provider>,
    );
    const list = container.querySelector('.scrollable');

    list.querySelectorAll('article').forEach((article, index) => {
      const id = ['100', '90', '80'][index];

      article.getBoundingClientRect = () => ({
        top: (index * 100) - nativeScrollTop.get.call(list),
        bottom: ((index + 1) * 100) - nativeScrollTop.get.call(list),
        height: 100,
        left: 0,
        right: 320,
        width: 320,
      });
      article.setAttribute('data-id', id);
    });
    list.getBoundingClientRect = () => ({ top: 0, bottom: 400, height: 400, left: 0, right: 320, width: 320 });
    nativeScrollTop.set.call(list, 1800);
    installSmoothScroll(list);
    scrollTop(list);
    flushFrames(1);

    const moved = listRef.current.scrollToLoadedStatus('80');

    expect(moved.ok).toBe(true);
    flushFrames(8);
    expect(nativeScrollTop.get.call(list)).toBe(200);
    expect(isProgrammaticTopScroll(list)).toBe(false);
  });
});

const buildSplitStore = () => {
  const reducer = combineReducers({ timelines, settings });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state.setIn(['timelines', 'list:42'], ImmutableMap({
    unread: 0,
    online: true,
    top: false,
    isLoading: false,
    hasMore: true,
    isPartial: false,
    pendingItems: ImmutableList(),
    items: ImmutableList(['100', '90', '80']),
  }));

  return createStore(reducer, state, applyMiddleware(thunk));
};

const SplitView = ({ split, multiColumn }) => (
  <Column ref={split.setColumnRef} bindToDocument={!multiColumn} label='Timeline'>
    <ColumnHeader icon='home' title='Timeline' onClick={split.handleHeaderClick} multiColumn={multiColumn} extraButton={split.splitButton} />
    {split.isSplit ? (
      <div className='timeline-split'>
        <div className='timeline-split__pane timeline-split__pane--live'>
          <div className='scrollable' data-pane='live' />
        </div>
        <div className='timeline-split__pane timeline-split__pane--history'>
          <div className='scrollable' data-pane='history' />
        </div>
      </div>
    ) : (
      <div className='scrollable' data-pane='single' />
    )}
  </Column>
);

class SplitHarness extends React.PureComponent {

  handleCommit = (ratio) => {
    this.props.dispatch(changeSetting(['list', 'splitRatio'], ratio));
  }

  render () {
    return (
      <StatusTimelineSplitController
        sourceTimelineId='list:42'
        columnId='column-a'
        multiColumn
        location={{ key: 'A', pathname: '/timelines/list/42' }}
        splitRatio={35}
        onSplitRatioCommit={this.handleCommit}
        unavailableMessage={{ id: 'timeline.split_unavailable', defaultMessage: 'Another timeline is already split' }}
      >
        {(split) => <SplitView split={split} multiColumn />}
      </StatusTimelineSplitController>
    );
  }

}

const ConnectedSplit = connect()(SplitHarness);

describe('split header smooth scroll', () => {
  let frames;

  beforeEach(() => {
    frames = [];
    const portal = document.createElement('div');

    portal.id = 'tabs-bar__portal';
    document.body.appendChild(portal);
    global.IntersectionObserver = class {

      observe () {}

      unobserve () {}

      disconnect () {}

    };
    jest.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => {
      frames.push(callback);
      return frames.length;
    });
  });

  afterEach(() => {
    document.body.innerHTML = '';
    jest.restoreAllMocks();
  });

  const flushFrames = (times = 8) => {
    for (let i = 0; i < times; i += 1) {
      const batch = frames.splice(0, frames.length);

      if (batch.length === 0) {
        break;
      }

      act(() => {
        batch.forEach(callback => callback && callback(0));
      });
    }
  };

  it('smooth-scrolls the live pane to zero and does not move history', () => {
    const { container } = render(
      <Provider store={buildSplitStore()}>
        <ConnectedSplit />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    flushFrames();
    const live = container.querySelector('.timeline-split__pane--live .scrollable');
    const history = container.querySelector('.timeline-split__pane--history .scrollable');
    let expected = 0;
    let sawProgrammatic = false;

    nativeScrollTop.set.call(live, 4100);
    nativeScrollTop.set.call(history, 640);
    live.scrollTo = (options = {}) => {
      const start = nativeScrollTop.get.call(live);
      let ticks = 0;

      expected = start;
      const step = () => {
        const programmatic = isProgrammaticTopScroll(live);

        if (programmatic) {
          sawProgrammatic = true;
        }

        const actual = nativeScrollTop.get.call(live);

        if (Math.abs(actual - expected) > 0.5 || (sawProgrammatic && !programmatic)) {
          return;
        }

        ticks += 1;
        const next = ticks >= 4 ? (options.top || 0) : start + (((options.top || 0) - start) * ticks / 4);

        nativeScrollTop.set.call(live, next);
        expected = next;

        if (next !== (options.top || 0)) {
          requestAnimationFrame(step);
        }
      };

      requestAnimationFrame(step);
    };

    fireEvent.click(screen.getByRole('button', { name: 'Timeline' }));
    flushFrames(1);
    const mid = nativeScrollTop.get.call(live);

    expect(mid).toBeGreaterThan(0);
    expect(mid).toBeLessThan(4100);
    nativeScrollTop.set.call(history, 640);
    restoreFilterAnchor({ offset: 50, rows: [], focused: null }, live, live, 0);
    flushFrames();

    expect(nativeScrollTop.get.call(live)).toBe(0);
    expect(nativeScrollTop.get.call(history)).toBe(640);
  });
});
