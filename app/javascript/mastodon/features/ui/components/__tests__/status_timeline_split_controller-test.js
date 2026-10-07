/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider, connect } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { changeSetting } from 'mastodon/actions/settings';
import Column from 'mastodon/components/column';
import ColumnHeader from 'mastodon/components/column_header';
import settings from 'mastodon/reducers/settings';
import timelines from 'mastodon/reducers/timelines';
import StatusTimelineSplitController, { STATUS_TIMELINE_SPLIT_LAYOUT_CLASS } from '../status_timeline_split_controller';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

const unavailableMessage = {
  id: 'timeline.split_unavailable',
  defaultMessage: 'Another timeline is already split',
};

const SplitView = ({ split, multiColumn }) => (
  <Column ref={split.setColumnRef} bindToDocument={!multiColumn} label='Timeline'>
    <ColumnHeader
      icon='home'
      title='Timeline'
      onClick={split.handleHeaderClick}
      extraButton={split.splitButton}
      multiColumn={multiColumn}
    />
    {split.isSplit ? (
      <div className='timeline-split' style={{ '--timeline-split-ratio': split.ratio }}>
        <div className='timeline-split__pane timeline-split__pane--live'>
          <div className='scrollable' data-pane='live'>
            <article data-id='100' />
            <article data-id='90' />
            <article data-id='80' />
          </div>
        </div>
        {split.splitter}
        <div className='timeline-split__pane timeline-split__pane--history'>
          <div className='scrollable' data-pane='history'>
            <article data-id='100' />
            <article data-id='90' />
            <article data-id='80' />
          </div>
        </div>
      </div>
    ) : (
      <div className='scrollable' data-pane='single'>
        <article data-id='100' />
        <article data-id='90' />
        <article data-id='80' />
      </div>
    )}
  </Column>
);

class Harness extends React.PureComponent {

  handleCommit = (ratio) => {
    this.props.dispatch(changeSetting(['list', 'splitRatio'], ratio));
  }

  renderSplit = (split) => (
    <SplitView split={split} multiColumn={this.props.multiColumn} />
  )

  render () {
    return (
      <StatusTimelineSplitController
        sourceTimelineId={this.props.sourceTimelineId}
        columnId={this.props.columnId}
        multiColumn={this.props.multiColumn}
        location={this.props.location}
        splitRatio={this.props.splitRatio}
        onSplitRatioCommit={this.handleCommit}
        unavailableMessage={unavailableMessage}
        splitContextKey={this.props.splitContextKey}
      >
        {this.renderSplit}
      </StatusTimelineSplitController>
    );
  }

}

const ConnectedHarness = connect(state => ({
  splitRatio: state.getIn(['settings', 'list', 'splitRatio'], 35),
}))(Harness);

const buildStore = (sources = ['list:42']) => {
  const reducer = combineReducers({ timelines, settings });
  let state = reducer(undefined, { type: '@@INIT' });

  sources.forEach(source => {
    state = state.setIn(['timelines', source], ImmutableMap({
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

const renderHarness = (store, props) => render(
  <Provider store={store}>
    <ConnectedHarness sourceTimelineId='list:42' {...props} />
  </Provider>,
);

const activeSplitId = (store, source = 'list:42') => store.getState().getIn(['timelines', source, 'splitTimelineId']);

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

const location = (key) => ({ key, pathname: '/timelines/list/42' });

const flushQueuedFrames = (frames) => {
  const batch = frames.splice(0, frames.length);

  act(() => {
    batch.forEach(callback => callback(0));
  });
};

describe('StatusTimelineSplitController', () => {
  beforeEach(() => {
    const portal = document.createElement('div');
    portal.id = 'tabs-bar__portal';
    document.body.appendChild(portal);
  });

  afterEach(() => {
    document.querySelectorAll('.tabs-bar__wrapper').forEach(node => node.remove());
    document.body.classList.remove(STATUS_TIMELINE_SPLIT_LAYOUT_CLASS);
    document.body.classList.remove('home-timeline-split');

    const portal = document.getElementById('tabs-bar__portal');

    if (portal) {
      portal.remove();
    }
  });

  it('creates and destroys a split for a colon-delimited source timeline', () => {
    const store = buildStore();
    const { container } = renderHarness(store, { columnId: 'column-a', multiColumn: true });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const splitTimelineId = activeSplitId(store);

    expect(splitTimelineId).toEqual(expect.stringMatching(/^list:42:split:column-a:.+/));
    expect(store.getState().getIn(['timelines', splitTimelineId, 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(container.querySelector('.timeline-split__pane--live .scrollable')).not.toBeNull();
    expect(container.querySelector('.timeline-split__pane--history .scrollable')).not.toBeNull();
    expect(document.body.classList.contains('home-timeline-split')).toBe(false);

    fireEvent.click(container.querySelector('.column-header__split-button'));

    expect(container.querySelector('.timeline-split')).toBeNull();
    expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
    expect(activeSplitId(store)).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'list:42', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(store.getState().getIn(['timelines', 'list:42', 'pendingItems']).includes('120')).toBe(true);
  });

  it('commits ratio changes separately from the home timeline ratio', () => {
    const store = buildStore();
    const { container } = renderHarness(store, { columnId: 'column-a', multiColumn: true });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const separator = container.querySelector('[role="separator"]');

    expect(separator).toHaveAttribute('aria-valuenow', '35');
    expect(store.getState().getIn(['settings', 'home', 'splitRatio'])).toBe(35);

    fireEvent.keyDown(separator, { key: 'ArrowDown' });

    expect(separator.getAttribute('aria-valuenow')).toBe('40');
    expect(store.getState().getIn(['settings', 'list', 'splitRatio'])).toBe(40);
    expect(store.getState().getIn(['settings', 'home', 'splitRatio'])).toBe(35);

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
    emitPointer('pointermove', document, 220);
    expect(store.getState().getIn(['settings', 'list', 'splitRatio'])).toBe(40);

    emitPointer('pointerup', document, 300);
    HTMLElement.prototype.getBoundingClientRect = originalRect;

    expect(store.getState().getIn(['settings', 'list', 'splitRatio'])).toBe(50);
    expect(store.getState().getIn(['settings', 'home', 'splitRatio'])).toBe(35);
  });

  it('restores the multi-column scroll offset into the history pane and back', () => {
    const store = buildStore();
    const { container } = renderHarness(store, { columnId: 'column-a', multiColumn: true });
    const before = container.querySelector('.scrollable');

    before.scrollTop = 320;
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const history = container.querySelector('.timeline-split__pane--history .scrollable');

    expect(history.scrollTop).toBe(320);

    history.scrollTop = 480;
    fireEvent.click(container.querySelector('.column-header__split-button'));

    expect(container.querySelector('.scrollable').scrollTop).toBe(480);
  });

  it('restores the visible status into the history pane and resets document scroll', () => {
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
    const { container } = renderHarness(store, { multiColumn: false, location: location('A') });

    scroller().scrollTop = 900;
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    restoreRects();

    expect(container.querySelector('.timeline-split__pane--history .scrollable').scrollTop).toBe(384);
    expect(scroller().scrollTop).toBe(0);
    expect(document.body.classList.contains(STATUS_TIMELINE_SPLIT_LAYOUT_CLASS)).toBe(true);
  });

  it('saves a return anchor on single-column unmount and restores it for the same location key', () => {
    const store = buildStore();
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
    mountTabsWrapper(0, 64);
    const view = renderHarness(store, { columnId: 'column-a', multiColumn: false, location: location('A') });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    view.container.querySelector('.timeline-split__pane--history .scrollable').scrollTop = 2386;
    view.unmount();

    const anchor = store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor']);

    expect(anchor.get('locationKey')).toBe('A');
    expect(anchor.get('id')).toBe('90');
    expect(anchor.get('offset')).toBeCloseTo(-7.84);
    expect(anchor.get('fallbackOffset')).toBe(2386);
    expect(activeSplitId(store)).toBeUndefined();

    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });

    scroller().scrollTop = 0;
    renderHarness(store, { multiColumn: false, location: location('A') });
    flushQueuedFrames(frames);
    flushQueuedFrames(frames);
    spy.mockRestore();
    restoreRects();

    expect(scroller().scrollTop).toBeCloseTo(343.84);
    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor'])).toBeUndefined();
  });

  it('saves the location key from a later history entry on the same source timeline', () => {
    const store = buildStore();
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
    mountTabsWrapper(0, 64);
    const view = renderHarness(store, { columnId: 'column-a', multiColumn: false, location: location('A') });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    view.container.querySelector('.timeline-split__pane--history .scrollable').scrollTop = 2386;
    view.rerender(
      <Provider store={store}>
        <ConnectedHarness sourceTimelineId='list:42' columnId='column-a' multiColumn={false} location={location('B')} />
      </Provider>,
    );
    view.unmount();

    const anchor = store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor']);

    expect(anchor.get('locationKey')).toBe('B');
    expect(anchor.get('id')).toBe('90');
    expect(anchor.get('offset')).toBeCloseTo(-7.84);
    expect(anchor.get('fallbackOffset')).toBe(2386);

    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });

    scroller().scrollTop = 0;
    renderHarness(store, { multiColumn: false, location: location('B') });
    flushQueuedFrames(frames);
    flushQueuedFrames(frames);
    spy.mockRestore();
    restoreRects();

    expect(scroller().scrollTop).toBeCloseTo(343.84);
    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor'])).toBeUndefined();
  });

  it('drops the active split and return anchor when the split context changes', () => {
    const store = buildStore();
    store.dispatch({
      type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR',
      timeline: 'list:42',
      anchor: { locationKey: 'A', id: '90', offset: -7.84, fallbackOffset: 2386 },
    });
    mountTabsWrapper(0, 64);
    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });
    const view = renderHarness(store, { columnId: 'column-a', multiColumn: false, location: location('A'), splitContextKey: 'ruby|any:|all:|none:' });
    const staleRestore = frames[0];

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = activeSplitId(store);
    store.dispatch({
      type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR',
      timeline: 'list:42',
      anchor: { locationKey: 'A', id: '90', offset: -7.84, fallbackOffset: 2386 },
    });
    view.container.querySelector('.timeline-split__pane--history .scrollable').scrollTop = 640;
    view.rerender(
      <Provider store={store}>
        <ConnectedHarness sourceTimelineId='list:42' columnId='column-a' multiColumn={false} location={location('A')} splitContextKey='ruby|any:a|all:|none:' />
      </Provider>,
    );
    act(() => {
      staleRestore(0);
    });
    spy.mockRestore();

    expect(view.container.querySelector('.timeline-split')).toBeNull();
    expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
    expect(activeSplitId(store)).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor'])).toBeUndefined();
    expect(scroller().scrollTop).toBe(0);
    expect(document.body.classList.contains(STATUS_TIMELINE_SPLIT_LAYOUT_CLASS)).toBe(false);
  });

  it('discards a return anchor when the location key differs or the layout is multi-column', () => {
    const store = buildStore();

    store.dispatch({
      type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR',
      timeline: 'list:42',
      anchor: { locationKey: 'A', id: '90', offset: -7.84, fallbackOffset: 2386 },
    });
    mountTabsWrapper(0, 64);
    scroller().scrollTop = 80;

    const mismatched = renderHarness(store, { multiColumn: false, location: location('B') });

    expect(scroller().scrollTop).toBe(80);
    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor'])).toBeUndefined();
    mismatched.unmount();

    store.dispatch({
      type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR',
      timeline: 'list:42',
      anchor: { locationKey: 'A', id: '90', offset: -7.84, fallbackOffset: 2386 },
    });
    scroller().scrollTop = 80;
    const multi = renderHarness(store, { columnId: 'column-a', multiColumn: true, location: location('A') });

    expect(scroller().scrollTop).toBe(80);
    expect(multi.container.querySelector('.timeline-split')).toBeNull();
    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor'])).toBeUndefined();
  });

  it('does not split or restore a scroll anchor while the source timeline is partial', () => {
    const store = buildStore();

    store.dispatch({ type: 'TIMELINE_MARK_AS_PARTIAL', timeline: 'list:42' });
    store.dispatch({
      type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR',
      timeline: 'list:42',
      anchor: { locationKey: 'A', id: '90', offset: -7.84, fallbackOffset: 2386 },
    });

    const blocked = renderHarness(store, { columnId: 'column-a', multiColumn: false, location: location('A') });
    const button = screen.getByRole('button', { name: 'Split timeline' });

    expect(button).toBeDisabled();
    fireEvent.click(button);
    expect(activeSplitId(store)).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor'])).toBeUndefined();
    blocked.unmount();

    store.dispatch({
      type: 'TIMELINE_EXPAND_SUCCESS',
      timeline: 'list:42',
      statuses: [{ id: '100' }, { id: '90' }, { id: '80' }],
      next: null,
      partial: false,
      isLoadingRecent: false,
      usePendingItems: false,
    });

    const { container } = renderHarness(store, { columnId: 'column-a', multiColumn: true });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    act(() => {
      store.dispatch({ type: 'TIMELINE_MARK_AS_PARTIAL', timeline: 'list:42' });
    });
    container.querySelector('.timeline-split__pane--history .scrollable').scrollTop = 640;
    fireEvent.click(container.querySelector('.column-header__split-button'));

    expect(container.querySelector('.timeline-split')).toBeNull();
    expect(container.querySelector('[data-pane="single"]').scrollTop).toBe(0);
    expect(activeSplitId(store)).toBeUndefined();
  });

  it('removes the split when the layout changes in either direction', () => {
    const store = buildStore();
    const multi = renderHarness(store, { columnId: 'column-a', multiColumn: true });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = activeSplitId(store);

    multi.rerender(
      <Provider store={store}>
        <ConnectedHarness sourceTimelineId='list:42' columnId='column-a' multiColumn={false} />
      </Provider>,
    );

    expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
    expect(activeSplitId(store)).toBeUndefined();
    multi.unmount();

    const single = renderHarness(store, { columnId: 'column-a', multiColumn: false, location: location('A') });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const nextSplitId = activeSplitId(store);

    expect(document.body.classList.contains(STATUS_TIMELINE_SPLIT_LAYOUT_CLASS)).toBe(true);

    single.rerender(
      <Provider store={store}>
        <ConnectedHarness sourceTimelineId='list:42' columnId='column-a' multiColumn location={location('A')} />
      </Provider>,
    );

    expect(store.getState().get('timelines').has(nextSplitId)).toBe(false);
    expect(activeSplitId(store)).toBeUndefined();
    expect(document.body.classList.contains(STATUS_TIMELINE_SPLIT_LAYOUT_CLASS)).toBe(false);
  });

  it('cancels a queued return restore when a new split starts', () => {
    const store = buildStore();

    store.dispatch({
      type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR',
      timeline: 'list:42',
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
    const { container } = renderHarness(store, { columnId: 'col-cancel', multiColumn: false, location: location('A') });
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
    expect(activeSplitId(store)).toEqual(expect.stringMatching(/^list:42:split:col-cancel:/));
    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor'])).toBeUndefined();
  });

  it('cleans up a split on unmount without saving a return anchor in multiple columns', () => {
    const store = buildStore();
    const { unmount } = renderHarness(store, { columnId: 'column-a', multiColumn: true, location: location('A') });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = activeSplitId(store);

    unmount();

    expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
    expect(activeSplitId(store)).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'list:42', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(store.getState().getIn(['timelines', 'list:42', 'splitReturnAnchor'])).toBeUndefined();
    expect(document.body.classList.contains(STATUS_TIMELINE_SPLIT_LAYOUT_CLASS)).toBe(false);
  });
});
