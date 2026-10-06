import { Map as ImmutableMap, fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { changeCompose } from '../../actions/compose';
import { createComposer, destroyComposer, targetComposerAction } from '../../actions/composer';
import { STORE_HYDRATE } from '../../actions/store';
import { TIMELINE_DELETE, TIMELINE_EXPIRE } from '../../actions/timelines';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';
import compose from '../compose';
import composers from '../composers';

const empty = () => composers(undefined, { type: '@@INIT' });

const withComposers = (...composerIds) => composerIds.reduce(
  (state, composerId) => composers(state, createComposer(composerId)),
  empty(),
);

describe('composers registry', () => {
  it('starts with an empty byId map', () => {
    expect(empty().get('byId').isEmpty()).toBe(true);
  });

  it('creates a non-primary composer from the single-instance initial state', () => {
    const state = composers(empty(), createComposer('composer-a'));
    const composerState = state.getIn(['byId', 'composer-a']);

    expect(composerState.get('text')).toEqual('');
    expect(composerState.get('mounted')).toBe(0);
    expect(state.hasIn(['byId', PRIMARY_COMPOSER_ID])).toBe(false);
  });

  it('ignores create for primary and other invalid composer ids', () => {
    const state = empty();

    expect(composers(state, createComposer(PRIMARY_COMPOSER_ID))).toBe(state);
    expect(composers(state, createComposer(''))).toBe(state);
    expect(composers(state, createComposer(null))).toBe(state);
    expect(state.get('byId').isEmpty()).toBe(true);
  });

  it('hydrates a new composer from a plain object seed', () => {
    const composerState = composers(empty(), createComposer('composer-a', {
      default_privacy: 'private',
      default_language: 'ja',
    })).getIn(['byId', 'composer-a']);

    expect(composerState.get('privacy')).toEqual('private');
    expect(composerState.get('language')).toEqual('ja');
    expect(composerState.get('text')).toEqual('');
    expect(composerState.get('idempotencyKey')).not.toBeNull();
  });

  it('hydrates a new composer from the supplied seed', () => {
    const seed = ImmutableMap({
      default_privacy: 'private',
      default_language: 'ja',
      default_searchability: 'private',
    });
    const composerState = composers(empty(), createComposer('composer-a', seed)).getIn(['byId', 'composer-a']);

    expect(composerState.get('privacy')).toEqual('private');
    expect(composerState.get('language')).toEqual('ja');
    expect(composerState.get('searchability')).toEqual('private');
    expect(composerState.get('text')).toEqual('');
    expect(composerState.get('media_attachments').isEmpty()).toBe(true);
    expect(composerState.get('idempotencyKey')).not.toBeNull();
  });

  it('does not reapply a later seed to an existing composer', () => {
    const created = composers(empty(), createComposer('composer-a', ImmutableMap({
      default_privacy: 'private',
      default_language: 'ja',
    })));
    const drafted = composers(created, targetComposerAction(changeCompose('draft'), 'composer-a'));
    const instance = drafted.getIn(['byId', 'composer-a']);
    const again = composers(drafted, createComposer('composer-a', ImmutableMap({
      default_privacy: 'public',
      default_language: 'en',
    })));

    expect(again).toBe(drafted);
    expect(again.getIn(['byId', 'composer-a'])).toBe(instance);
    expect(again.getIn(['byId', 'composer-a', 'text'])).toEqual('draft');
  });

  it('does not reset an existing composer when create is repeated', () => {
    const created = withComposers('composer-a');
    const drafted = composers(created, targetComposerAction(changeCompose('hello'), 'composer-a'));
    const again = composers(drafted, createComposer('composer-a'));

    expect(again).toBe(drafted);
    expect(again.getIn(['byId', 'composer-a', 'text'])).toEqual('hello');
  });

  it('keeps composers isolated from each other', () => {
    const created = withComposers('composer-a', 'composer-b');
    const initialB = created.getIn(['byId', 'composer-b']);
    const changedA = composers(created, targetComposerAction(changeCompose('aaa'), 'composer-a'));

    expect(changedA.getIn(['byId', 'composer-a', 'text'])).toEqual('aaa');
    expect(changedA.getIn(['byId', 'composer-b'])).toBe(initialB);
    expect(changedA.getIn(['byId', 'composer-b', 'text'])).toEqual('');

    const changedB = composers(changedA, targetComposerAction(changeCompose('bbb'), 'composer-b'));

    expect(changedB.getIn(['byId', 'composer-a', 'text'])).toEqual('aaa');
    expect(changedB.getIn(['byId', 'composer-b', 'text'])).toEqual('bbb');
  });

  it('ignores legacy actions', () => {
    const state = withComposers('composer-a');

    expect(composers(state, changeCompose('legacy'))).toBe(state);
    expect(state.getIn(['byId', 'composer-a', 'text'])).toEqual('');
  });

  it('ignores explicit primary actions', () => {
    const state = withComposers('composer-a');
    const action = targetComposerAction(changeCompose('primary'), PRIMARY_COMPOSER_ID);

    expect(composers(state, action)).toBe(state);
  });

  it('does not create a composer for an unknown target', () => {
    const state = empty();
    const next = composers(state, targetComposerAction(changeCompose('late response'), 'missing'));

    expect(next).toBe(state);
    expect(next.hasIn(['byId', 'missing'])).toBe(false);
  });

  it('destroys only the requested composer', () => {
    const state = withComposers('composer-a', 'composer-b');
    const next = composers(state, destroyComposer('composer-a'));

    expect(next.hasIn(['byId', 'composer-a'])).toBe(false);
    expect(next.hasIn(['byId', 'composer-b'])).toBe(true);
  });

  it('ignores destroy for a missing composer and for primary', () => {
    const state = withComposers('composer-a');

    expect(composers(state, destroyComposer('missing'))).toBe(state);
    expect(composers(state, destroyComposer(PRIMARY_COMPOSER_ID))).toBe(state);
  });

  it('does not resurrect a composer from an action that arrives after destroy', () => {
    const state = composers(withComposers('composer-a'), destroyComposer('composer-a'));
    const next = composers(state, targetComposerAction(changeCompose('late'), 'composer-a'));

    expect(next).toBe(state);
    expect(next.hasIn(['byId', 'composer-a'])).toBe(false);
  });

  it('ignores root STORE_HYDRATE', () => {
    const state = withComposers('composer-a');
    const next = composers(state, {
      type: STORE_HYDRATE,
      state: fromJS({
        composers: {
          byId: {
            ghost: { text: 'hydrated' },
          },
        },
      }),
    });

    expect(next).toBe(state);
  });

  it.each([TIMELINE_DELETE, TIMELINE_EXPIRE])('broadcasts %s to every portable composer', type => {
    const state = withComposers('composer-a', 'composer-b')
      .setIn(['byId', 'composer-a', 'in_reply_to'], 'status-1')
      .setIn(['byId', 'composer-b', 'in_reply_to'], 'status-2');
    const next = composers(state, { type, id: 'status-1' });

    expect(next.getIn(['byId', 'composer-a', 'in_reply_to'])).toBeNull();
    expect(next.getIn(['byId', 'composer-b', 'in_reply_to'])).toEqual('status-2');
  });
});

describe('primary and registry routing', () => {
  const primary = compose(undefined, { type: '@@INIT' });
  const registry = withComposers('composer-a');

  it('updates only the targeted registry composer', () => {
    const action = targetComposerAction(changeCompose('A'), 'composer-a');

    expect(compose(primary, action)).toBe(primary);
    expect(composers(registry, action).getIn(['byId', 'composer-a', 'text'])).toEqual('A');
  });

  it('updates only the primary composer for a legacy action', () => {
    const action = changeCompose('legacy');

    expect(compose(primary, action).get('text')).toEqual('legacy');
    expect(composers(registry, action)).toBe(registry);
  });
});
