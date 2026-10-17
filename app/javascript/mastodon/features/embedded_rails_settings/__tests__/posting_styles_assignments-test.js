import React from 'react';
import PropTypes from 'prop-types';
import { act, render } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('mastodon/initial_state', () => ({ ...jest.requireActual('mastodon/initial_state'), isAdministrator: true, showComposerPostingStyleSelector: true }));
jest.mock('mastodon/api', () => ({ __esModule: true, default: jest.fn() }));
jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => props => <Component {...props} intl={{ formatMessage: ({ defaultMessage }) => defaultMessage }} />,
}));

import api from 'mastodon/api';
import { applyComposerSurface, createComposer, targetComposerAction } from 'mastodon/actions/composer';
import { fetchUserPostingContextAssignment, refreshUserPostingContextAssignments, resetUserPostingContextAssignment, saveUserPostingContextAssignment } from 'mastodon/actions/user_posting_context_assignments';
import { fetchUserPostingStyles } from 'mastodon/actions/user_posting_styles';
import compose from 'mastodon/reducers/compose';
import composers from 'mastodon/reducers/composers';
import userPostingStyles from 'mastodon/reducers/user_posting_styles';
import userPostingContextAssignments from 'mastodon/reducers/user_posting_context_assignments';
import { groupPostingContext } from 'mastodon/posting_context/fixtures/group_context_fixture';
import { ComposerProvider } from '../../compose/composer_id_context';
import UserPostingStyleController from '../../compose/containers/user_posting_style_controller';
import UserPostingStylePicker from '../../compose/containers/user_posting_style_picker_container';
import { submitEmbeddedSettings } from '../requests';

const surface = { kind: 'group', key: '123' };
const cacheKey = 'group:123';
const first = 'portable:first', second = 'portable:second', fresh = 'portable:fresh';
const assignment = status => ({ surface, status, style_id: status === 'style' ? '2' : null, revision: status === 'unset' ? null : 2 });
const rawStyles = [
  { id: '1', name: 'Dedicated', target: { kind: 'group', account_id: '123' }, defaults: { visibility: 'unlisted' }, managed: { hashtags: [] } },
  { id: '2', name: 'Shared saved', target: { kind: 'none' }, defaults: { visibility: 'public' }, managed: { hashtags: [] } },
];
const pending = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => {
    resolve = yes; reject = no;
  });
  return { promise, resolve, reject };
};
const composerAt = (store, id) => store.getState().getIn(['composers', 'byId', id]);
const cached = store => store.getState().getIn(['userPostingContextAssignments', 'bySurface', cacheKey]);
const Panels = ({ store, ids }) => (
  <Provider store={store}>
    <MemoryRouter>
      <div>{ids.map(id => <ComposerProvider key={id} composerId={id}><UserPostingStyleController /><UserPostingStylePicker header /></ComposerProvider>)}</div>
    </MemoryRouter>
  </Provider>
);

Panels.propTypes = { store: PropTypes.object.isRequired, ids: PropTypes.arrayOf(PropTypes.string).isRequired };

async function setup() {
  const server = { assignment: assignment('style'), styles: rawStyles };
  const get = jest.fn(path => Promise.resolve({ data: path.includes('user_posting_context_assignments') ? server.assignment : server.styles }));
  const put = jest.fn();
  const remove = jest.fn();
  api.mockReturnValue({ get, put, delete: remove });
  const store = createStore(combineReducers({ compose, composers, userPostingStyles, userPostingContextAssignments }), applyMiddleware(thunk));
  await store.dispatch(fetchUserPostingStyles());
  await store.dispatch(fetchUserPostingContextAssignment(surface));
  for (const id of [first, second]) {
    store.dispatch(createComposer(id));
    store.dispatch(applyComposerSurface(id, surface, groupPostingContext, '123'));
  }
  let view;
  await act(async () => {
    view = render(<Panels store={store} ids={[first, second]} />);
  });
  act(() => {
    for (const id of [first, second]) store.dispatch(targetComposerAction({ type: 'COMPOSE_CHANGE', text: `Keep ${id}` }, id));
  });
  expect(document.querySelectorAll('.compose-form__style-default-mark')).toHaveLength(2);
  expect(composerAt(store, first).getIn(['userPostingStyle', 'snapshot', 'id'])).toBe('2');
  expect(composerAt(store, first).getIn(['userPostingStyle', 'defaultsSettledSurface'])).toBe(cacheKey);
  return { store, server, get, put, remove, view };
}

const saveRails = (store, { path = '/settings/user_posting_context_assignments/7/decline', method = 'post' } = {}) => {
  const body = new FormData(); body.set('_method', method);
  return submitEmbeddedSettings('postingStyles', new URL(`${path}?embedded=1`, window.location.origin), body, store.dispatch);
};

it.each([
  ['decline', 'none', null, false, false],
  ['release', 'unset', '1', false, false],
  ['delete style', 'none', null, true, false],
  ['ambiguous committed decline', 'none', null, false, true],
])('reconciles %s for two open pickers and a new Composer without changing evaluated drafts', async (operation, status, selectedId, deleted, failed) => {
  const { store, server, view } = await setup();
  const before = [composerAt(store, first), composerAt(store, second)];
  const primary = store.getState().get('compose');
  window.fetch = jest.fn(async () => {
    server.assignment = assignment(status);
    if (deleted) server.styles = rawStyles.slice(0, 1);
    if (failed) throw new Error('connection lost after commit');
    return { ok: true };
  });
  await act(async () => {
    const save = saveRails(store, deleted ? { path: '/settings/user_posting_contexts/2', method: 'delete' } : { path: `/settings/user_posting_context_assignments/7/${status === 'unset' ? 'release' : 'decline'}` });
    if (failed) await expect(save).rejects.toThrow('connection lost'); else await save;
  });
  expect(cached(store).get('assignmentStatus')).toBe(status);
  expect(cached(store).get('styleId')).toBeNull();
  expect(document.querySelectorAll('.compose-form__style-default-mark')).toHaveLength(0);
  expect(composerAt(store, first)).toBe(before[0]);
  expect(composerAt(store, second)).toBe(before[1]);
  expect(store.getState().get('compose')).toBe(primary);
  expect(window.fetch).toHaveBeenCalledTimes(1);
  await act(async () => {
    store.dispatch(createComposer(fresh));
    store.dispatch(applyComposerSurface(fresh, surface, groupPostingContext, '123'));
    view.rerender(<Panels store={store} ids={[first, second, fresh]} />);
  });
  expect(composerAt(store, fresh).getIn(['userPostingStyle', 'selectedId'])).toBe(selectedId);
  expect(composerAt(store, fresh).getIn(['userPostingStyle', 'defaultsSettledSurface'])).toBe(cacheKey);
  expect(composerAt(store, first)).toBe(before[0]);
  expect(composerAt(store, second)).toBe(before[1]);
});

it.each(['GET', 'failed GET', 'write', 'failed write'])('does not resurrect a stale default from an old %s response after Rails completion', async kind => {
  const { store, server, get, put, view } = await setup();
  const before = [composerAt(store, first), composerAt(store, second)];
  const old = pending();
  let request;
  act(() => {
    if (kind.includes('GET')) {
      get.mockImplementationOnce(() => old.promise);
      request = store.dispatch(fetchUserPostingContextAssignment(surface, { force: true }));
    } else {
      put.mockReturnValueOnce(old.promise);
      request = store.dispatch(saveUserPostingContextAssignment(surface, '2'));
    }
  });
  window.fetch = jest.fn(async () => {
    server.assignment = assignment('none'); return { ok: true };
  });
  await act(async () => {
    await saveRails(store);
  });
  expect(cached(store).get('assignmentStatus')).toBe('none');
  const observed = [];
  const unsubscribe = store.subscribe(() => observed.push(cached(store).get('styleId')));
  await act(async () => {
    if (kind.startsWith('failed')) old.reject(new Error('old request offline')); else old.resolve({ data: assignment('style') });
    await request;
  });
  unsubscribe();
  expect(observed).not.toContain('2');
  expect(cached(store).get('assignmentStatus')).toBe('none');
  expect(document.querySelectorAll('.compose-form__style-default-mark')).toHaveLength(0);
  expect(composerAt(store, first)).toBe(before[0]);
  expect(composerAt(store, second)).toBe(before[1]);
  if (kind.includes('write')) expect(get.mock.calls.filter(([path]) => path.includes('user_posting_context_assignments'))).toHaveLength(3);
  await act(async () => {
    store.dispatch(createComposer(fresh));
    store.dispatch(applyComposerSurface(fresh, surface, groupPostingContext, '123'));
    view.rerender(<Panels store={store} ids={[first, second, fresh]} />);
  });
  expect(composerAt(store, fresh).getIn(['userPostingStyle', 'selectedId'])).toBeNull();
  expect(composerAt(store, first)).toBe(before[0]);
  expect(composerAt(store, second)).toBe(before[1]);
});

it('keeps invalidated defaults non-authoritative when reconciliation fails, including for a new Composer', async () => {
  const { store, get, view } = await setup();
  const before = composerAt(store, first);
  get.mockImplementation(path => path.includes('user_posting_context_assignments') ? Promise.reject(new Error('offline')) : Promise.resolve({ data: rawStyles }));
  window.fetch = jest.fn(async () => ({ ok: true }));
  await act(async () => {
    await saveRails(store);
  });
  expect(cached(store).get('status')).toBe('failed');
  expect(cached(store).get('styleId')).toBeNull();
  await act(async () => {
    store.dispatch(createComposer(fresh));
    store.dispatch(applyComposerSurface(fresh, surface, groupPostingContext, '123'));
    view.rerender(<Panels store={store} ids={[first, second, fresh]} />);
  });
  expect(composerAt(store, fresh).getIn(['userPostingStyle', 'selectedId'])).toBeNull();
  expect(composerAt(store, fresh).getIn(['userPostingStyle', 'defaultsSettledSurface'])).toBeNull();
  expect(composerAt(store, first)).toBe(before);
});

it.each(['success', 'failure'])('keeps write A locked across GET ready until A settles (%s), suppressing write B and DELETE', async outcome => {
  const { store, server, put, remove, view } = await setup();
  const before = [composerAt(store, first), composerAt(store, second)];
  const old = pending();
  put.mockReturnValueOnce(old.promise);
  let writeA;
  act(() => {
    writeA = store.dispatch(saveUserPostingContextAssignment(surface, '2'));
  });
  window.fetch = jest.fn(async () => {
    server.assignment = assignment('none'); return { ok: true };
  });
  await act(async () => {
    await saveRails(store);
  });
  expect(cached(store).get('status')).toBe('ready');
  expect(cached(store).get('writePending')).toBe(true);
  // The picker remains busy even though the independent GET has finished.
  expect(document.querySelectorAll('.compose-form__style-default-status').length).toBeGreaterThan(0);
  await act(async () => {
    await store.dispatch(saveUserPostingContextAssignment(surface, '1'));
    await store.dispatch(resetUserPostingContextAssignment(surface));
    store.dispatch(createComposer(fresh));
    store.dispatch(applyComposerSurface(fresh, surface, groupPostingContext, '123'));
    view.rerender(<Panels store={store} ids={[first, second, fresh]} />);
  });
  expect(put).toHaveBeenCalledTimes(1);
  expect(remove).not.toHaveBeenCalled();
  expect(composerAt(store, fresh).getIn(['userPostingStyle', 'defaultsSettledSurface'])).toBeNull();
  await act(async () => {
    if (outcome === 'success') old.resolve({ data: assignment('style') }); else old.reject(new Error('write A failed'));
    await writeA;
  });
  expect(cached(store).get('writePending')).toBe(false);
  expect(cached(store).get('assignmentStatus')).toBe('none');
  expect(composerAt(store, fresh).getIn(['userPostingStyle', 'selectedId'])).toBeNull();
  expect(composerAt(store, fresh).getIn(['userPostingStyle', 'defaultsSettledSurface'])).toBe(cacheKey);
  expect(composerAt(store, first)).toBe(before[0]);
  expect(composerAt(store, second)).toBe(before[1]);
  put.mockResolvedValueOnce({ data: assignment('style') });
  await act(async () => {
    await store.dispatch(saveUserPostingContextAssignment(surface, '2'));
  });
  expect(put).toHaveBeenCalledTimes(2);
});

it('invalidates 500 cached places but fetches only one mounted surface, then lazily reads a revisited place', async () => {
  const { store, server, get, view } = await setup();
  // Seed a realistic cache via real request/success actions, without mounting these places.
  get.mockImplementation((path, options) => Promise.resolve({ data: path.includes('user_posting_context_assignments')
    ? { ...assignment('style'), surface: { kind: options.params.surface_kind, key: options.params.surface_key } } : rawStyles }));
  await act(async () => {
    for (let i = 0; i < 500; i++) await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: String(1000 + i) }));
  });
  const before = composerAt(store, first);
  get.mockClear();
  get.mockImplementation((path, options) => Promise.resolve({ data: path.includes('user_posting_context_assignments')
    ? { ...server.assignment, surface: { kind: options.params.surface_kind, key: options.params.surface_key } } : rawStyles }));
  server.assignment = assignment('none');
  await act(async () => {
    await store.dispatch(refreshUserPostingContextAssignments());
  });
  expect(get).toHaveBeenCalledTimes(1); // both mounted controllers share group:123
  const closed = store.getState().getIn(['userPostingContextAssignments', 'bySurface', 'group:1000']);
  expect(closed.get('status')).toBe('idle');
  expect(closed.get('styleId')).toBeNull();
  expect(composerAt(store, first)).toBe(before);
  await act(async () => {
    store.dispatch(createComposer(fresh));
    store.dispatch(applyComposerSurface(fresh, { kind: 'group', key: '1000' }, groupPostingContext, '1000'));
    view.rerender(<Panels store={store} ids={[first, second, fresh]} />);
  });
  expect(get).toHaveBeenCalledTimes(2);
  expect(get.mock.calls[1][1].params.surface_key).toBe('1000');
  expect(composerAt(store, fresh).getIn(['userPostingStyle', 'selectedId'])).toBeNull();
  expect(composerAt(store, fresh).getIn(['userPostingStyle', 'defaultsSettledSurface'])).toBe('group:1000');
  await act(async () => {
    view.rerender(<Panels store={store} ids={[second]} />);
  });
  expect(store.getState().getIn(['userPostingContextAssignments', 'mountedSurfaces']).size).toBe(1);
  get.mockClear();
  await act(async () => {
    await store.dispatch(refreshUserPostingContextAssignments());
  });
  expect(get).toHaveBeenCalledTimes(1); // unmounting one of two consumers does not forget the remaining one
  view.unmount();
  get.mockClear();
  expect(store.getState().getIn(['userPostingContextAssignments', 'mountedSurfaces']).size).toBe(0);
  await store.dispatch(refreshUserPostingContextAssignments());
  expect(get).not.toHaveBeenCalled();
});
