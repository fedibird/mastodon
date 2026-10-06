jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { COMPOSE_CHANGE, changeCompose } from '../compose';
import { targetComposerAction } from '../composer';

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
