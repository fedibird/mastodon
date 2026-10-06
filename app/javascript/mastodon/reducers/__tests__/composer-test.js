import { fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../uuid', () => ({
  __esModule: true,
  default: () => 'test-idempotency-key',
}));

import { COMPOSE_CHANGE, changeCompose } from '../../actions/compose';
import { targetComposerAction } from '../../actions/composer';
import { STORE_HYDRATE } from '../../actions/store';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';
import compose from '../compose';
import composer from '../composer';

const changeAction = {
  type: COMPOSE_CHANGE,
  text: 'hello',
};

const hydrateAction = {
  type: STORE_HYDRATE,
  state: fromJS({
    compose: {
      text: 'hydrated',
      default_language: 'ja',
    },
  }),
};

describe('composer', () => {
  it('initializes a single composer state', () => {
    const state = composer(undefined, { type: '@@INIT' });

    expect(state.get('text')).toEqual('');
    expect(state.get('privacy')).toBeNull();
  });

  it('handles an ordinary compose action without the primary wrapper', () => {
    const state = composer(undefined, { type: '@@INIT' });
    const next = composer(state, changeAction);

    expect(next.get('text')).toEqual('hello');
    expect(next.get('dirty')).toBe(true);
  });

  it('ignores root STORE_HYDRATE', () => {
    const state = composer(undefined, { type: '@@INIT' }).set('text', 'keep');

    expect(composer(state, hydrateAction)).toBe(state);
  });
});

describe('compose primary wrapper', () => {
  it('hydrates the primary compose slice', () => {
    const state = composer(undefined, { type: '@@INIT' }).set('text', 'keep');
    const next = compose(state, hydrateAction);

    expect(next.get('default_language')).toEqual('ja');
    expect(next.get('language')).toEqual('ja');
    expect(next.get('text')).toEqual('hydrated');
  });

  it('delegates ordinary actions to the single-instance reducer', () => {
    const state = composer(undefined, { type: '@@INIT' });

    expect(compose(state, changeAction)).toEqual(composer(state, changeAction));
  });

  it('hydrates the primary slice before composer targeting', () => {
    const state = composer(undefined, { type: '@@INIT' }).set('text', 'keep');
    const next = compose(state, {
      ...hydrateAction,
      meta: { composerId: 'composer-a' },
    });

    expect(next.get('default_language')).toEqual('ja');
    expect(next.get('language')).toEqual('ja');
    expect(next.get('text')).toEqual('hydrated');
  });

  it('applies a legacy action to the primary composer', () => {
    const state = composer(undefined, { type: '@@INIT' });
    const next = compose(state, changeCompose('legacy'));

    expect(next.get('text')).toEqual('legacy');
  });

  it('applies an explicit primary action to the primary composer', () => {
    const state = composer(undefined, { type: '@@INIT' });
    const next = compose(state, targetComposerAction(changeCompose('primary'), PRIMARY_COMPOSER_ID));

    expect(next.get('text')).toEqual('primary');
  });

  it('leaves the primary composer unchanged for an explicit non-primary action', () => {
    const state = composer(undefined, { type: '@@INIT' });
    const next = compose(state, targetComposerAction(changeCompose('other'), 'composer-a'));

    expect(next).toBe(state);
  });
});

describe('composer routing metadata', () => {
  it('applies a targeted action when called directly', () => {
    const state = composer(undefined, { type: '@@INIT' });
    const next = composer(state, targetComposerAction(changeCompose('other'), 'composer-a'));

    expect(next.get('text')).toEqual('other');
  });
});
