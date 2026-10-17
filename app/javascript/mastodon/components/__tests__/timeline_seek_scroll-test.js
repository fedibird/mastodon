jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
  FormattedMessage: () => null,
  FormattedNumber: () => null,
}));

import { act, fireEvent, render } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
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
jest.mock('../../filter_reconciliation/surface', () => ({
  FilterSurface: class {

    update () {}

    destroy () {}

    intersection () {}

    prepare () {}

  },
}));

import StatusList from '../status_list';

const store = () => createStore(combineReducers({
  dropdown_menu: (state = ImmutableMap()) => state,
  height_cache: (state = ImmutableMap()) => state,
}));

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

const seekProps = (ids, extra = {}) => ({
  scrollKey: 'history',
  statusIds: ImmutableList(ids),
  trackScroll: false,
  trackIntersection: false,
  hasMore: false,
  windowedHistory: true,
  windowRevision: 1,
  seekScrollPending: false,
  ...extra,
});

describe('StatusList seek scroll', () => {
  let frames;

  beforeEach(() => {
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
    document.body.innerHTML = '';
    jest.restoreAllMocks();
  });

  const flushFrames = () => {
    const batch = frames.splice(0, frames.length);

    act(() => {
      batch.forEach(callback => callback && callback(0));
    });
  };

  const mounted = (props) => {
    const reduxStore = store();
    const view = render(
      <Provider store={reduxStore}>
        <StatusList {...props} />
      </Provider>,
    );

    return {
      ...view,
      update (next) {
        view.rerender(
          <Provider store={reduxStore}>
            <StatusList {...next} />
          </Provider>,
        );
      },
    };
  };

  it('scrolls to an unloaded id only after the new window has rendered', () => {
    const onSeekScroll = jest.fn();
    const view = mounted(seekProps(['100', '90', '80']));

    view.update(seekProps(['100', '90', '80', '70'], {
      windowRevision: 2,
      seekScrollPending: true,
      seekSessionId: 'seek-1',
      seekAnchorId: '70',
      seekScrollRevision: 2,
      onSeekScroll,
    }));
    const list = view.container.querySelector('.scrollable');

    layoutArticles(list, { 100: 100, 90: 100, 80: 100, 70: 100 });

    expect(list.scrollTop).toBe(0);
    expect(onSeekScroll).not.toHaveBeenCalled();
    expect(list.querySelector('article[data-id="70"]')).not.toBeNull();

    flushFrames();

    expect(list.scrollTop).toBe(300);
    expect(onSeekScroll).toHaveBeenCalledTimes(1);
    expect(onSeekScroll.mock.calls[0][0]).toEqual(expect.objectContaining({
      sessionId: 'seek-1',
      revision: 2,
      anchorId: '70',
      scrolled: true,
      reason: 'loaded',
    }));
  });

  it('does not move when the rendered list filtered the anchor out', () => {
    const onSeekScroll = jest.fn();
    const view = mounted(seekProps(['100', '90', '80'], {
      windowRevision: 2,
      seekScrollPending: true,
      seekSessionId: 'seek-1',
      seekAnchorId: '70',
      seekScrollRevision: 2,
      onSeekScroll,
    }));
    const list = view.container.querySelector('.scrollable');

    layoutArticles(list, { 100: 100, 90: 100, 80: 100 });
    list.scrollTop = 40;
    flushFrames();

    expect(list.scrollTop).toBe(40);
    expect(list.querySelector('article[data-id="70"]')).toBeNull();
    expect(onSeekScroll).toHaveBeenCalledTimes(1);
    expect(onSeekScroll.mock.calls[0][0]).toEqual(expect.objectContaining({
      scrolled: false,
      reason: 'filtered',
    }));
  });

  it('reports not_loaded when the id is in the list but the article is gone', () => {
    const onSeekScroll = jest.fn();
    const view = mounted(seekProps(['100', '90', '70'], {
      windowRevision: 2,
      seekScrollPending: true,
      seekSessionId: 'seek-1',
      seekAnchorId: '70',
      seekScrollRevision: 2,
      onSeekScroll,
    }));
    const list = view.container.querySelector('.scrollable');
    const article = list.querySelector('article[data-id="70"]');

    article.remove();
    flushFrames();

    expect(list.scrollTop).toBe(0);
    expect(onSeekScroll.mock.calls[0][0].reason).toBe('not_loaded');
    expect(onSeekScroll.mock.calls[0][0].scrolled).toBe(false);
  });

  it('drops the frame when the seek session changes or the list unmounts', () => {
    const onSeekScroll = jest.fn();
    const pending = {
      windowRevision: 2,
      seekScrollPending: true,
      seekSessionId: 'seek-1',
      seekAnchorId: '80',
      seekScrollRevision: 2,
      onSeekScroll,
    };
    const view = mounted(seekProps(['100', '90', '80'], pending));
    const list = view.container.querySelector('.scrollable');

    layoutArticles(list, { 100: 100, 90: 100, 80: 100 });
    view.update(seekProps(['100', '90', '80'], {
      windowRevision: 3,
      seekScrollPending: false,
    }));
    flushFrames();
    expect(onSeekScroll).not.toHaveBeenCalled();
    expect(list.scrollTop).toBe(0);

    view.update(seekProps(['100', '90', '80'], pending));
    view.unmount();
    expect(() => flushFrames()).not.toThrow();
    expect(onSeekScroll).not.toHaveBeenCalled();
  });

  it('cancels a pending jump scroll when the reader scrolls the history pane', () => {
    const onSeekScroll = jest.fn();
    const view = mounted(seekProps(['100', '90', '80'], {
      windowRevision: 2,
      seekScrollPending: true,
      seekSessionId: 'seek-1',
      seekAnchorId: '80',
      seekScrollRevision: 2,
      historySurfaceId: 'home:split:1',
      onSeekScroll,
    }));
    const list = view.container.querySelector('.scrollable');

    layoutArticles(list, { 100: 100, 90: 100, 80: 100 });
    fireEvent.wheel(list, { deltaY: 30 });
    flushFrames();

    expect(onSeekScroll).toHaveBeenCalledTimes(1);
    expect(onSeekScroll.mock.calls[0][0]).toEqual(expect.objectContaining({
      sessionId: 'seek-1',
      revision: 2,
      anchorId: '80',
      scrolled: false,
      reason: 'user_scroll',
    }));
    expect(list.scrollTop).toBe(0);
  });
});
