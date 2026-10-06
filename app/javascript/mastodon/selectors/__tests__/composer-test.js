import { fromJS } from 'immutable';

import { PRIMARY_COMPOSER_ID, selectComposer } from '../composer';

const compose = fromJS({
  text: 'hello',
  language: 'ja',
});

const state = fromJS({
  compose,
});

describe('selectComposer', () => {
  it('returns the same Immutable compose map when the primary composer id is explicit', () => {
    expect(selectComposer(state, PRIMARY_COMPOSER_ID)).toBe(state.get('compose'));
  });

  it('defaults to the primary composer and keeps the existing map identity', () => {
    expect(selectComposer(state)).toBe(state.get('compose'));
  });

  it('returns null for an unknown composer id', () => {
    expect(selectComposer(state, 'other')).toBeNull();
  });

  it('defines the primary composer id', () => {
    expect(PRIMARY_COMPOSER_ID).toBe('primary');
  });
});
