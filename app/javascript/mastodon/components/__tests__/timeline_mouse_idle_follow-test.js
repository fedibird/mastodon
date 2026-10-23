jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
  FormattedMessage: () => null,
  FormattedNumber: () => null,
}));

import { act, fireEvent, render } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('../../containers/scroll_container', () => ({ children }) => children);

import ScrollableList from '../scrollable_list';

const ROW_HEIGHT = 200;

const store = () => createStore(() => ImmutableMap({
  dropdown_menu: ImmutableMap(),
  filterMatches: ImmutableMap({ baseline: true, generation: 0, entries: ImmutableMap() }),
  statuses: ImmutableMap(),
}), applyMiddleware(thunk));

const Row = () => <span className='timeline-follow-row' />;

const items = (ids) => ids.map(id => <Row key={id} />);

const arm = (list) => {
  list.handleMouseMove();
  list.handleMouseMove.flush();
};

const renderList = ({ bindToDocument = false, ids = ['100'], scrollKey = 'public' } = {}) => {
  const ref = React.createRef();
  const redux = store();
  const props = { scrollKey, bindToDocument };
  const tree = (nextIds, nextProps = props) => (
    <Provider store={redux}>
      <ScrollableList ref={ref} scrollKey={nextProps.scrollKey} trackScroll={false} hasMore={false} bindToDocument={nextProps.bindToDocument}>
        {items(nextIds)}
      </ScrollableList>
    </Provider>
  );
  const view = render(tree(ids));
  const list = view.container.querySelector('.scrollable');
  const scroller = bindToDocument ? (document.scrollingElement || document.body) : list;

  if (bindToDocument) {
    Object.defineProperty(scroller, 'scrollHeight', { configurable: true, get: () => 8000 });
    Object.defineProperty(scroller, 'clientHeight', { configurable: true, get: () => 600 });
  }

  jest.spyOn(ref.current, 'getScrollHeight').mockImplementation(() => (
    list.querySelectorAll('article[data-id]').length * ROW_HEIGHT
  ));
  jest.spyOn(ref.current, 'getClientHeight').mockImplementation(() => 600);

  return { view, ref, list, scroller, tree };
};

const show = (mounted, ids, nextProps) => {
  mounted.view.rerender(mounted.tree(ids, nextProps));
};

describe('ScrollableList mouse-idle follow', () => {
  beforeEach(() => {
    global.IntersectionObserver = class {

      observe () {}

      unobserve () {}

      disconnect () {}

      takeRecords () {
        return [];
      }

    };
    Object.defineProperty(document, 'hidden', { configurable: true, value: false });
  });

  afterEach(() => {
    const scroller = document.scrollingElement || document.body;

    delete scroller.scrollHeight;
    delete scroller.clientHeight;
    scroller.scrollTop = 0;
    document.body.innerHTML = '';
    jest.restoreAllMocks();
    jest.useRealTimers();
  });

  it.each(['element', 'document'])('returns to the latest row after a streamed insert on %s scroll', (host) => {
    const mounted = renderList({ bindToDocument: host === 'document' });
    const { ref, scroller } = mounted;

    scroller.scrollTop = 0;
    arm(ref.current);
    expect(ref.current.scrollToTopOnMouseIdle).toBe(true);

    show(mounted, ['200', '100']);
    expect(scroller.scrollTop).toBe(ROW_HEIGHT);

    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(0);

    show(mounted, ['300', '200', '100']);
    expect(scroller.scrollTop).toBe(0);
  });

  it.each(['element', 'document'])('keeps following when several rows arrive during one mouse-move on %s scroll', (host) => {
    const mounted = renderList({ bindToDocument: host === 'document' });
    const { ref, scroller } = mounted;

    scroller.scrollTop = 0;
    arm(ref.current);
    show(mounted, ['200', '100']);
    expect(scroller.scrollTop).toBe(ROW_HEIGHT);

    arm(ref.current);
    show(mounted, ['300', '200', '100']);
    expect(scroller.scrollTop).toBe(ROW_HEIGHT * 2);

    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(0);
    show(mounted, ['400', '300', '200', '100']);
    expect(scroller.scrollTop).toBe(0);
  });

  it('snaps when the idle timer fires after the insertion correction', () => {
    jest.useFakeTimers('modern');
    const mounted = renderList();
    const { ref, scroller } = mounted;

    scroller.scrollTop = 0;
    arm(ref.current);
    show(mounted, ['200', '100']);
    expect(scroller.scrollTop).toBe(ROW_HEIGHT);

    act(() => {
      jest.advanceTimersByTime(300);
    });
    expect(scroller.scrollTop).toBe(0);
  });

  it('keeps the top without a mousemove when a row is prepended', () => {
    const mounted = renderList();
    const { scroller } = mounted;

    scroller.scrollTop = 0;
    show(mounted, ['200', '100']);
    expect(scroller.scrollTop).toBe(0);
  });

  it('still follows when the insertion scroll event is delivered', () => {
    const mounted = renderList();
    const { ref, list, scroller } = mounted;
    let top = 0;

    Object.defineProperty(list, 'scrollTop', {
      configurable: true,
      get: () => top,
      set (value) {
        top = Number(value) || 0;
        list.dispatchEvent(new Event('scroll'));
      },
    });
    scroller.scrollTop = 0;
    arm(ref.current);
    show(mounted, ['200', '100']);
    ref.current.handleScroll.flush();
    expect(scroller.scrollTop).toBe(ROW_HEIGHT);

    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(0);
  });

  it('does not snap a scrollbar move that never delivered a scroll event', () => {
    const mounted = renderList();
    const { ref, scroller } = mounted;

    scroller.scrollTop = 0;
    arm(ref.current);
    scroller.scrollTop = 420;
    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(420);
  });

  it('does not ratify a prior user move when the next insert corrects it', () => {
    const mounted = renderList();
    const { ref, scroller } = mounted;

    scroller.scrollTop = 0;
    arm(ref.current);
    scroller.scrollTop = 420;
    show(mounted, ['200', '100']);
    expect(scroller.scrollTop).toBe(420 + ROW_HEIGHT);

    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(420 + ROW_HEIGHT);
  });

  it('does not snap a 2px scrollbar move, and a later insert does not adopt it', () => {
    const mounted = renderList();
    const { ref, scroller } = mounted;

    scroller.scrollTop = 0;
    arm(ref.current);
    scroller.scrollTop = 2;
    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(2);

    arm(ref.current);
    scroller.scrollTop = 2;
    show(mounted, ['200', '100']);
    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).not.toBe(0);
  });

  it.each([
    ['wheel', (node) => fireEvent.wheel(node)],
    ['touchmove', (node) => fireEvent.touchMove(node)],
    ['ArrowDown', (node) => fireEvent.keyDown(node, { key: 'ArrowDown' })],
    ['pointer drag', (node) => node.dispatchEvent(new MouseEvent('pointermove', { bubbles: true, buttons: 1 }))],
  ])('does not snap back to the top after %s once an insert corrects position', (label, emit) => {
    const mounted = renderList();
    const { ref, list, scroller } = mounted;

    scroller.scrollTop = 0;
    arm(ref.current);
    emit(list);
    show(mounted, ['200', '100']);
    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(ROW_HEIGHT);
    expect(label).toBe(label);
  });

  it('does not let a delivered scroll event after a real move become an app correction', () => {
    const mounted = renderList();
    const { ref, list, scroller } = mounted;

    scroller.scrollTop = 0;
    arm(ref.current);
    scroller.scrollTop = 420;
    fireEvent.scroll(list);
    ref.current.handleScroll.flush();
    show(mounted, ['200', '100']);
    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).toBe(420 + ROW_HEIGHT);
  });

  it('does not pull a seek back to the top, even after a later insert', () => {
    const mounted = renderList({ ids: ['100', '90'] });
    const { ref, list, scroller } = mounted;

    list.querySelectorAll('article[data-id]').forEach((article) => {
      const index = article.getAttribute('data-id') === '100' ? 0 : 1;

      article.getBoundingClientRect = () => ({
        top: (index * ROW_HEIGHT) - scroller.scrollTop,
        bottom: ((index + 1) * ROW_HEIGHT) - scroller.scrollTop,
        height: ROW_HEIGHT,
        left: 0,
        right: 320,
        width: 320,
      });
    });
    list.getBoundingClientRect = () => ({ top: 0, bottom: 600, height: 600, left: 0, right: 320, width: 320 });
    scroller.scrollTop = 0;
    arm(ref.current);

    const moved = ref.current.scrollToLoadedStatus('90');

    expect(moved.ok).toBe(true);
    const parked = scroller.scrollTop;

    expect(parked).toBeGreaterThan(0);
    show(mounted, ['200', '100', '90']);
    ref.current.handleMouseIdle();
    expect(scroller.scrollTop).not.toBe(0);
  });

  it('does not let a route change replay an armed snap', () => {
    const mounted = renderList({ scrollKey: 'public' });
    const { view, ref, list, scroller, tree } = mounted;

    scroller.scrollTop = 0;
    arm(ref.current);
    show(mounted, ['200', '100']);
    expect(scroller.scrollTop).toBe(ROW_HEIGHT);
    const session = ref.current._mouseIdleSession;

    view.rerender(tree(['200', '100'], { scrollKey: 'home', bindToDocument: false }));
    ref.current.handleMouseIdle(session);
    expect(list.scrollTop).toBe(ROW_HEIGHT);
  });

  it('does not snap after unmount when the idle timer fires', () => {
    jest.useFakeTimers('modern');
    const mounted = renderList();
    const { view, ref, scroller } = mounted;

    scroller.scrollTop = 0;
    arm(ref.current);
    show(mounted, ['200', '100']);
    const top = scroller.scrollTop;

    view.unmount();
    expect(() => {
      act(() => {
        jest.advanceTimersByTime(400);
      });
    }).not.toThrow();
    expect(top).toBe(ROW_HEIGHT);
  });

  it('leaves the sibling column where the reader put it', () => {
    const left = React.createRef();
    const right = React.createRef();
    const redux = store();
    const tree = (leftIds, rightIds) => (
      <Provider store={redux}>
        <div>
          <ScrollableList ref={left} scrollKey='column-a' trackScroll={false} hasMore={false}>
            {items(leftIds)}
          </ScrollableList>
          <ScrollableList ref={right} scrollKey='column-b' trackScroll={false} hasMore={false}>
            {items(rightIds)}
          </ScrollableList>
        </div>
      </Provider>
    );
    const view = render(tree(['100'], ['100']));
    const lists = view.container.querySelectorAll('.scrollable');

    jest.spyOn(left.current, 'getScrollHeight').mockImplementation(() => (
      lists[0].querySelectorAll('article[data-id]').length * ROW_HEIGHT
    ));
    lists[0].scrollTop = 0;
    lists[1].scrollTop = 420;
    arm(left.current);
    view.rerender(tree(['200', '100'], ['100']));
    left.current.handleMouseIdle();
    expect(lists[0].scrollTop).toBe(0);
    expect(lists[1].scrollTop).toBe(420);
  });
});
