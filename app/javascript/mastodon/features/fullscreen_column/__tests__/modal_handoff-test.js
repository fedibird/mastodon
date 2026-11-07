/* eslint-disable react/prop-types, react/jsx-no-bind */
import React from 'react';
import { act, render } from '@testing-library/react';
import { Provider, connect } from 'react-redux';
import { createStore, applyMiddleware } from 'redux';
import thunk from 'redux-thunk';
import { Router } from 'react-router-dom';
import { createMemoryHistory } from 'history';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import { unstable_batchedUpdates } from 'react-dom';
import ModalRoot from 'mastodon/components/modal_root';
import { closeModal, openModal } from 'mastodon/actions/modal';
import { dismissFullscreenModals, pushFullscreenPath, setFullscreenComposerOpen } from 'mastodon/actions/fullscreen_column';
import fullscreenColumn from 'mastodon/reducers/fullscreen_column';
import modal from 'mastodon/reducers/modal';
import { resetOverlayLayersForTests } from 'mastodon/utils/overlay_layers';

jest.mock('mastodon/features/compose/portable_composer', () => () => null);
jest.mock('mastodon/features/fullscreen_column/components/stream', () => () => null);
jest.mock('mastodon/features/fullscreen_column/components/detail', () => () => null);
jest.mock('mastodon/features/fullscreen_column/components/bar', () => () => null);

import FullscreenColumnHost from 'mastodon/features/fullscreen_column';

const rootReducer = (state, action) => {
  const nextFullscreen = fullscreenColumn(state.get('fullscreenColumn'), action);
  const nextModal = modal(state.get('modal'), action);

  if (nextFullscreen === state.get('fullscreenColumn') && nextModal === state.get('modal')) {
    return state;
  }

  return state.set('fullscreenColumn', nextFullscreen).set('modal', nextModal);
};

const sessionState = () => ImmutableMap({
  meta: ImmutableMap({ layout: 'multi-column' }),
  fullscreenColumn: null,
  modal: ImmutableList(),
  compose: fromJS({ text: 'primary draft', dirty: true, mounted: true, references: [] }),
  composers: fromJS({
    byId: {
      'fullscreen:a': { text: 'draft a', dirty: true, mounted: true, references: ['7'] },
    },
  }),
});

let activeStore;

const ColumnAndModal = connect((state) => ({
  open: state.get('modal').size > 0,
}))(({ open }) => (
  <div>
    <FullscreenColumnHost />
    <ModalRoot onClose={() => activeStore.dispatch(closeModal())}>
      {open ? <div>media</div> : null}
    </ModalRoot>
  </div>
));

const Harness = ({ store, history }) => (
  <Provider store={store}>
    <Router history={history}>
      <ColumnAndModal />
    </Router>
  </Provider>
);

const openColumn = (store) => {
  store.dispatch({
    type: 'FULLSCREEN_COLUMN_OPEN',
    viewId: 'view-1',
    composerId: 'fullscreen:a',
    source: { kind: 'timeline', title: 'Home', supportsComposer: true },
    presentation: { appearance: 'normal', columns: 1, scale: 'small' },
  });
};

const mountColumn = () => {
  const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
  const store = createStore(rootReducer, sessionState(), applyMiddleware(thunk));

  activeStore = store;
  const view = render(<Harness store={store} history={history} />);

  act(() => {
    openColumn(store);
  });
  act(() => {
    store.dispatch(openModal('MEDIA', { statusId: '42' }));
  });

  return { history, store, view };
};

describe('fullscreen handoff from a media modal', () => {
  afterEach(() => {
    resetOverlayLayersForTests();
  });

  it('keeps the opened status after the media modal pops its history entry', () => {
    const { history, store, view } = mountColumn();

    act(() => {
      unstable_batchedUpdates(() => {
        store.dispatch(closeModal());
        store.dispatch(pushFullscreenPath('/statuses/42'));
      });
    });
    expect(store.getState().getIn(['fullscreenColumn', 'paths']).toArray()).toEqual(['/statuses/42']);
    expect(store.getState().getIn(['fullscreenColumn', 'open'])).toBe(true);
    expect(history.location.state.mastodonFullscreenDepth).toBe(2);
    expect(history.location.state.mastodonModalKey).toBeUndefined();
    expect(history.location.pathname).toBe('/timelines/home');

    act(() => {
      history.goBack();
    });

    expect(store.getState().getIn(['fullscreenColumn', 'paths']).toArray()).toEqual([]);
    expect(store.getState().getIn(['fullscreenColumn', 'open'])).toBe(true);
    view.unmount();
  });

  it('keeps the reply composer after the media modal pops its history entry', () => {
    const { history, store, view } = mountColumn();

    act(() => {
      unstable_batchedUpdates(() => {
        store.dispatch(closeModal());
        store.dispatch(setFullscreenComposerOpen(true));
      });
    });
    expect(store.getState().getIn(['fullscreenColumn', 'composerOpen'])).toBe(true);
    expect(store.getState().getIn(['fullscreenColumn', 'open'])).toBe(true);
    expect(history.location.state.mastodonFullscreenDepth).toBe(2);
    expect(history.location.state.mastodonModalKey).toBeUndefined();
    expect(store.getState().getIn(['compose', 'text'])).toBe('primary draft');

    act(() => {
      history.goBack();
    });

    expect(store.getState().getIn(['fullscreenColumn', 'composerOpen'])).toBe(false);
    expect(store.getState().getIn(['fullscreenColumn', 'open'])).toBe(true);
    view.unmount();
  });

  it('closes the media modal with a reference and returns to the first history entry', () => {
    const { history, store, view } = mountColumn();

    act(() => {
      store.dispatch(openModal('CONFIRM', { message: 'match' }));
    });
    act(() => {
      unstable_batchedUpdates(() => {
        store.dispatch((dispatch) => {
          dispatch(closeModal());
          dispatch(dismissFullscreenModals());
          dispatch(setFullscreenComposerOpen(true));
        });
      });
    });

    expect(store.getState().get('modal').size).toBe(0);
    expect(store.getState().getIn(['fullscreenColumn', 'composerOpen'])).toBe(true);
    expect(history.location.state.mastodonFullscreenDepth).toBe(2);
    expect(history.location.state.mastodonModalKey).toBeUndefined();

    act(() => {
      history.goBack();
    });

    expect(store.getState().getIn(['fullscreenColumn', 'composerOpen'])).toBe(false);
    expect(store.getState().getIn(['fullscreenColumn', 'open'])).toBe(true);
    expect(history.location.state.mastodonModalKey).toBeUndefined();

    act(() => {
      history.go(-history.location.state.mastodonFullscreenDepth);
    });

    expect(history.location.pathname).toBe('/timelines/home');
    expect(history.location.state && history.location.state.mastodonFullscreenKey).toBeUndefined();
    expect(history.location.state && history.location.state.mastodonModalKey).toBeUndefined();
    view.unmount();
  });
});
