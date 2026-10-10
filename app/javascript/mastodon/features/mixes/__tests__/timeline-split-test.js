import { act, fireEvent, render, screen } from '@testing-library/react';
import { Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { MemoryRouter } from 'react-router-dom';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => {
  const ReactMock = require('react');
  const intl = {
    formatMessage: (message, values) => {
      let text = message.defaultMessage || message.id;

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
    injectIntl: Component => props => <ReactMock.Fragment><Component {...props} intl={intl} /></ReactMock.Fragment>,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/initial_state', () => ({
  get me () {
    return '1';
  },
  get isAdministrator () {
    return true;
  },
  get new_features_policy () {
    return 'tester';
  },
  defaultColumnWidth: 'wide',
}));

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: () => ({
    get: (...args) => mockGet(...args),
    put: () => Promise.resolve({ data: {} }),
  }),
  getLinks: (response) => (response && response.links) || { refs: [] },
}));

jest.mock('mastodon/actions/mix_streaming', () => ({
  openMixStream: () => () => {},
  closeMixStream: () => () => {},
  pinMixStream: () => () => {},
  revealMixStream: () => () => {},
  reconcileMixSource: () => () => {},
}));

jest.mock('mastodon/actions/importer', () => ({
  importFetchedStatuses: (statuses) => ({ type: 'IMPORT_STATUSES', statuses }),
  importFetchedAccounts: (accounts) => ({ type: 'IMPORT_ACCOUNTS', accounts }),
  importFilters: (filters) => ({ type: 'FILTERS_IMPORT', filters }),
}));

jest.mock('../../../components/status_list', () => {
  const ReactMock = require('react');

  return function StatusList (props) {
    const ids = props.statusIds && props.statusIds.toArray ? props.statusIds.toArray() : [];

    return ReactMock.createElement('div', {
      className: 'scrollable',
      'data-track-intersection': props.trackIntersection === false ? 'false' : 'true',
      'data-bind': props.bindToDocument ? 'document' : 'column',
    },
    props.prepend,
    ids.map(id => ReactMock.createElement('article', { key: id, 'data-id': id })),
    props.hasMore && props.onLoadMore
      ? ReactMock.createElement('button', { type: 'button', onClick: () => props.onLoadMore() }, 'Load older')
      : null,
    );
  };
});

const mockGet = jest.fn();

import mixTimelines from 'mastodon/reducers/mix_timelines';
import settings from 'mastodon/reducers/settings';
import MixTimeline from '../timeline';

const mix = {
  id: 'mix-1',
  title: 'Desk',
  version: 1,
  sources: [
    { type: 'home', params: {} },
    { type: 'public', params: {} },
  ],
};

const reducer = combineReducers({
  mix_timelines: mixTimelines,
  settings,
  statuses: (state = ImmutableMap()) => state || ImmutableMap(),
  filters: (state = ImmutableMap()) => state || ImmutableMap(),
  timelines: (state = ImmutableMap()) => state || ImmutableMap(),
  relationships: (state = ImmutableMap()) => state || ImmutableMap(),
});

const buildStore = () => createStore(reducer, fromJS({
  settings: {
    mixes: [mix],
    columns: [],
  },
}), applyMiddleware(thunk));

const range = (start) => {
  const data = [];

  for (let value = start; value > start - 40; value -= 1) {
    data.push({ id: String(value), account: { id: '2' }, visibility: 'public' });
  }

  return data;
};

const pageFor = (path, config) => {
  const maxId = config && config.params && config.params.max_id;

  if (maxId) {
    return Promise.resolve({
      status: 200,
      data: [{ id: '30', account: { id: '2' }, visibility: 'public' }],
      headers: {},
    });
  }

  return Promise.resolve({
    status: 200,
    data: range(80),
    links: { refs: [{ rel: 'next', uri: `${window.location.origin}${path}?max_id=40` }] },
  });
};

const flush = async () => {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
};

const renderMixes = (store, props) => render(
  <Provider store={store}>
    <MemoryRouter>
      <MixTimeline params={{ id: 'mix-1' }} {...props} />
    </MemoryRouter>
  </Provider>,
);

describe('mix timeline split controls', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockGet.mockImplementation(pageFor);
    const portal = document.createElement('div');

    portal.id = 'tabs-bar__portal';
    document.body.appendChild(portal);
  });

  afterEach(() => {
    const portal = document.getElementById('tabs-bar__portal');

    if (portal) {
      portal.remove();
    }
  });

  it('splits, pages history, saves the ratio, and closes either pane', async () => {
    const store = buildStore();
    const view = renderMixes(store, { columnId: 'alpha', multiColumn: true });

    await flush();

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const region = screen.getByRole('region', { name: 'Desk' });
    const live = region.querySelector('.timeline-split__pane--live .scrollable');
    const history = region.querySelector('.timeline-split__pane--history .scrollable');

    expect(live).not.toBeNull();
    expect(history).not.toBeNull();
    expect(live.getAttribute('data-track-intersection')).toBe('false');
    expect(history.getAttribute('data-track-intersection')).toBe('true');
    expect(live.getAttribute('data-bind')).toBe('column');
    expect(Array.from(live.querySelectorAll('article')).map(article => article.getAttribute('data-id'))).toEqual(expect.arrayContaining(['80', '70']));

    const callsBefore = mockGet.mock.calls.length;

    fireEvent.click(screen.getByRole('button', { name: 'Load older' }));
    await flush();

    expect(mockGet.mock.calls.length).toBeGreaterThan(callsBefore);
    expect(Array.from(history.querySelectorAll('article')).map(article => article.getAttribute('data-id'))).toContain('30');
    expect(Array.from(live.querySelectorAll('article')).map(article => article.getAttribute('data-id'))).not.toContain('30');

    fireEvent.keyDown(screen.getByRole('separator', { name: 'Timeline splitter' }), { key: 'ArrowDown' });
    expect(store.getState().getIn(['settings', 'mixTimeline', 'splitRatio'])).toBe(40);

    history.scrollTop = 180;
    fireEvent.click(screen.getByRole('button', { name: 'Close live pane' }));

    expect(store.getState().getIn(['mix_timelines', 'column:alpha', 'split'])).toBeUndefined();
    expect(store.getState().getIn(['mix_timelines', 'column:alpha', 'pinnedToTop'])).toBe(false);
    expect(region.querySelector('.timeline-split')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    fireEvent.click(screen.getByRole('button', { name: 'Close history pane' }));

    expect(store.getState().getIn(['mix_timelines', 'column:alpha', 'displayMode'])).toBe('live');
    expect(store.getState().getIn(['mix_timelines', 'column:alpha', 'split'])).toBeUndefined();
    view.unmount();
  });

  it('keeps two columns of the same mix independent', async () => {
    const store = buildStore();

    render(
      <Provider store={store}>
        <MemoryRouter>
          <div>
            <MixTimeline params={{ id: 'mix-1' }} columnId='alpha' multiColumn />
            <MixTimeline params={{ id: 'mix-1' }} columnId='beta' multiColumn />
          </div>
        </MemoryRouter>
      </Provider>,
    );
    await flush();

    const regions = screen.getAllByRole('region', { name: 'Desk' });

    fireEvent.click(regions[0].querySelector('button[aria-label="Split timeline"]'));

    expect(store.getState().getIn(['mix_timelines', 'column:alpha', 'split', 'id'])).toEqual(expect.any(String));
    expect(store.getState().getIn(['mix_timelines', 'column:beta', 'split'])).toBeUndefined();
    expect(regions[1].querySelector('.timeline-split')).toBeNull();
  });

  it('restores a single-column anchor only for the same location key', async () => {
    const store = buildStore();
    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });
    const first = renderMixes(store, { multiColumn: false, location: { key: 'route-a' } });

    await flush();
    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    first.unmount();

    expect(store.getState().getIn(['mix_timelines', '__anchors', 'route:mix-1', 'locationKey'])).toBe('route-a');

    renderMixes(store, { multiColumn: false, location: { key: 'route-b' } });
    await flush();
    frames.splice(0).forEach(callback => callback());

    expect(store.getState().getIn(['mix_timelines', '__anchors', 'route:mix-1'])).toBeUndefined();
    spy.mockRestore();
  });
});
