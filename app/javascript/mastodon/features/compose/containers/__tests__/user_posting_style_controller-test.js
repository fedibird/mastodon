import { act, render } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('../../../../initial_state', () => ({
  ...jest.requireActual('../../../../initial_state'),
  isAdministrator: true,
}));

jest.mock('../../../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
}));

import api from '../../../../api';
import { acceptComposerSurface, applyComposerSurface, createComposer, targetComposerAction } from '../../../../actions/composer';
import { groupPostingContext } from '../../../../posting_context/fixtures/group_context_fixture';
import composers from '../../../../reducers/composers';
import userPostingContextAssignments from '../../../../reducers/user_posting_context_assignments';
import userPostingStyles from '../../../../reducers/user_posting_styles';
import { ComposerProvider } from '../../composer_id_context';
import UserPostingStyleController from '../user_posting_style_controller';

const reduce = (state, action) => {
  if (!state || !action || action.type === '@@INIT') {
    return state;
  }

  return state
    .set('composers', composers(state.get('composers'), action))
    .set('userPostingStyles', userPostingStyles(state.get('userPostingStyles'), action))
    .set('userPostingContextAssignments', userPostingContextAssignments(state.get('userPostingContextAssignments'), action));
};

const assignmentGets = get => get.mock.calls.filter(call => String(call[0]).includes('user_posting_context_assignments')).length;

describe('UserPostingStyleController place defaults', () => {
  beforeEach(() => {
    api.mockReset();
  });

  it('does not repeat a failed assignment read when the composer updates', async () => {
    const composerId = 'portable:group-column:123';
    const store = createStore(reduce, ImmutableMap({
      composers: composers(undefined, createComposer(composerId)),
      userPostingStyles: userPostingStyles(undefined, { type: '@@INIT' }),
      userPostingContextAssignments: userPostingContextAssignments(undefined, { type: '@@INIT' }),
    }), applyMiddleware(thunk));

    store.dispatch(applyComposerSurface(composerId, { kind: 'group', key: '123' }, groupPostingContext, '123'));

    const get = jest.fn(path => (
      String(path).includes('user_posting_context_assignments')
        ? Promise.reject(new Error('down'))
        : Promise.resolve({ data: [] })
    ));

    api.mockReturnValue({ get });

    await act(async () => {
      render(
        <Provider store={store}>
          <ComposerProvider composerId={composerId}>
            <UserPostingStyleController />
          </ComposerProvider>
        </Provider>,
      );
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(assignmentGets(get)).toEqual(1);
    expect(store.getState().getIn(['userPostingContextAssignments', 'bySurface', 'group:123', 'status'])).toEqual('failed');

    await act(async () => {
      store.dispatch(targetComposerAction({ type: 'COMPOSE_CHANGE', text: 'one' }, composerId));
      store.dispatch(targetComposerAction({ type: 'COMPOSE_CHANGE', text: 'two' }, composerId));
      store.dispatch(targetComposerAction({ type: 'COMPOSE_CHANGE', text: 'three' }, composerId));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(assignmentGets(get)).toEqual(1);

    get.mockImplementation(path => (
      String(path).includes('user_posting_context_assignments')
        ? Promise.resolve({
          data: {
            surface: { kind: 'group', key: '456' },
            status: 'unset',
            style_id: null,
            revision: null,
          },
        })
        : Promise.resolve({ data: [] })
    ));

    await act(async () => {
      store.dispatch(applyComposerSurface(composerId, { kind: 'group', key: '456' }, groupPostingContext, '456'));
      await Promise.resolve();
    });

    expect(assignmentGets(get)).toEqual(1);
    expect(store.getState().getIn(['composers', 'byId', composerId, 'surface', 'key'])).toEqual('123');

    await act(async () => {
      store.dispatch(acceptComposerSurface(composerId));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(assignmentGets(get)).toEqual(2);
    expect(store.getState().getIn(['userPostingContextAssignments', 'bySurface', 'group:123', 'status'])).toEqual('failed');
    expect(store.getState().getIn(['userPostingContextAssignments', 'bySurface', 'group:456', 'status'])).toEqual('ready');
  });
});
