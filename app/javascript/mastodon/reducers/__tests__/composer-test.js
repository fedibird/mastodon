import { fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../uuid', () => ({
  __esModule: true,
  default: () => 'test-idempotency-key',
}));

import { COMPOSE_CHANGE } from '../../actions/compose';
import { STORE_HYDRATE } from '../../actions/store';
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
});
