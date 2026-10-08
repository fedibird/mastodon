jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { COMPOSE_CHANGE, changeCompose } from '../compose';
import {
  COMPOSER_CONTEXT_APPLY,
  COMPOSER_CONTEXT_HASHTAG_TOGGLE,
  COMPOSER_CREATE,
  COMPOSER_DESTROY,
  applyComposerPostingContext,
  createComposer,
  destroyComposer,
  targetComposerAction,
  toggleComposerManagedHashtag,
} from '../composer';

describe('targetComposerAction', () => {
  it('adds a composer id to a plain action', () => {
    const action = changeCompose('hello');
    const targeted = targetComposerAction(action, 'composer-a');

    expect(targeted).toEqual({
      type: COMPOSE_CHANGE,
      text: 'hello',
      meta: {
        composerId: 'composer-a',
      },
    });
  });

  it('does not mutate the original action', () => {
    const action = changeCompose('hello');

    targetComposerAction(action, 'other');

    expect(action.meta).toBeUndefined();
    expect(action).toEqual({
      type: COMPOSE_CHANGE,
      text: 'hello',
    });
  });

  it('keeps existing meta on a new meta object', () => {
    const action = {
      type: 'TEST',
      meta: {
        existing: true,
      },
    };
    const targeted = targetComposerAction(action, 'composer-a');

    expect(targeted.meta).toEqual({
      existing: true,
      composerId: 'composer-a',
    });
    expect(targeted.meta).not.toBe(action.meta);
    expect(action.meta).toEqual({
      existing: true,
    });
  });
});

describe('composer lifecycle actions', () => {
  it('targets create at the requested composer', () => {
    expect(createComposer('composer-a')).toEqual({
      type: COMPOSER_CREATE,
      meta: {
        composerId: 'composer-a',
      },
    });
  });

  it('keeps an optional seed on the create action', () => {
    const seed = { default_privacy: 'private' };

    expect(createComposer('composer-a', seed)).toEqual({
      type: COMPOSER_CREATE,
      seed,
      meta: {
        composerId: 'composer-a',
      },
    });
  });

  it('targets posting context application', () => {
    const postingContext = { key: 'builtin:hashtag:foo' };

    expect(applyComposerPostingContext('composer-a', postingContext)).toEqual({
      type: COMPOSER_CONTEXT_APPLY,
      postingContext,
      postingContextAccountId: null,
      meta: {
        composerId: 'composer-a',
      },
    });
    expect(applyComposerPostingContext('composer-a', null).postingContext).toBeNull();
    expect(applyComposerPostingContext('composer-a', null).postingContextAccountId).toBeNull();
    expect(applyComposerPostingContext('composer-a', postingContext, 456).postingContextAccountId).toEqual('456');
  });

  it('targets managed hashtag suppression', () => {
    expect(toggleComposerManagedHashtag('composer-a', 'foo')).toEqual({
      type: COMPOSER_CONTEXT_HASHTAG_TOGGLE,
      normalizedName: 'foo',
      meta: {
        composerId: 'composer-a',
      },
    });
  });

  it('targets destroy at the requested composer', () => {
    expect(destroyComposer('composer-a')).toEqual({
      type: COMPOSER_DESTROY,
      meta: {
        composerId: 'composer-a',
      },
    });
  });
});
