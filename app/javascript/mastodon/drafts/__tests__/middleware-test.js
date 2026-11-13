import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';
import { combineReducers } from 'redux-immutable';
import { changeCompose, COMPOSE_SUBMIT_SUCCESS } from '../../actions/compose';
import { createComposer, destroyComposer, targetComposerAction } from '../../actions/composer';
import compose from '../../reducers/compose';
import composerDraftRecovery from '../../reducers/composer_draft_recovery';
import composers from '../../reducers/composers';
import { composerDraftMiddleware } from '../middleware';
import { createComposerDraftSession } from '../session';
import { createMemoryDraftBackend } from '../storage';

function storeFor () {
  const backend = createMemoryDraftBackend();
  let clock = 0;
  const session = createComposerDraftSession({
    backend,
    now: () => {
      clock += 1;
      return `2026-11-13T00:00:0${clock}.000Z`;
    },
    createId: (() => {
      let next = 0;

      return () => {
        next += 1;
        return `draft-${next}`;
      };
    })(),
    schedule: (fn) => fn,
    cancel: () => undefined,
  });
  const store = createStore(
    combineReducers({
      compose,
      composers,
      composerDraftRecovery,
    }),
    applyMiddleware(thunk, composerDraftMiddleware({
      session,
      backend,
      accountId: '42',
      target: null,
    })),
  );

  return { store, session, backend };
}

describe('composer draft middleware', () => {
  it('saves primary and portable composers separately and restores only an empty surface', async () => {
    const { store, session, backend } = storeFor();

    store.dispatch(changeCompose('primary text'));
    store.dispatch(createComposer('portable-a'));
    store.dispatch(createComposer('portable-b'));
    store.dispatch(targetComposerAction(changeCompose('from a'), 'portable-a'));
    store.dispatch(targetComposerAction(changeCompose('from b'), 'portable-b'));
    await session.flush();
    store.dispatch(destroyComposer('portable-a'));
    await session.flush();
    await session.refreshOffers('42');

    const texts = (await backend.listDrafts('42')).map(item => item.input.text).sort();

    expect(texts).toEqual(['from a', 'from b', 'primary text']);

    store.dispatch(changeCompose('still typing'));
    const before = store.getState().getIn(['compose', 'text']);
    const offer = (await backend.listDrafts('42')).find(item => item.input.text === 'from a');

    store.dispatch(targetComposerAction({
      type: 'COMPOSER_DRAFT_RESTORE',
      snapshot: offer,
      idempotencyKey: 'should-not-apply',
      baseRevision: offer.revision,
    }, 'primary'));

    expect(store.getState().getIn(['compose', 'text'])).toBe(before);

    store.dispatch(changeCompose(''));
    store.dispatch(targetComposerAction({
      type: 'COMPOSER_DRAFT_RESTORE',
      snapshot: offer,
      idempotencyKey: 'restore-key',
      baseRevision: offer.revision,
    }, 'primary'));

    expect(store.getState().getIn(['compose', 'text'])).toBe('from a');
    expect(store.getState().getIn(['composers', 'byId', 'portable-b', 'text'])).toBe('from b');
  });

  it('removes a draft after a successful post and does not recreate it from the cleared composer', async () => {
    const { store, session, backend } = storeFor();

    store.dispatch(changeCompose('to post'));
    await session.flush();
    store.dispatch({
      type: COMPOSE_SUBMIT_SUCCESS,
      submission: null,
    });
    await session.flush();

    expect(await backend.listDrafts('42')).toEqual([]);
    expect(store.getState().getIn(['compose', 'text'])).toBe('');
  });
});
