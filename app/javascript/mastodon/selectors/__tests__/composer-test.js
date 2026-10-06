import { fromJS } from 'immutable';

import { PRIMARY_COMPOSER_ID, getComposerStatePath, selectComposer } from '../composer';

const compose = fromJS({
  text: 'hello',
  language: 'ja',
});

const portable = fromJS({
  text: 'portable',
  language: 'en',
});

const state = fromJS({
  compose,
  composers: {
    byId: {
      'composer-a': portable,
    },
  },
});

describe('selectComposer', () => {
  it('returns the same Immutable compose map when the primary composer id is explicit', () => {
    expect(selectComposer(state, PRIMARY_COMPOSER_ID)).toBe(state.get('compose'));
  });

  it('defaults to the primary composer and keeps the existing map identity', () => {
    expect(selectComposer(state)).toBe(state.get('compose'));
  });

  it('returns the registry composer by identity', () => {
    expect(selectComposer(state, 'composer-a')).toBe(state.getIn(['composers', 'byId', 'composer-a']));
  });

  it('returns null for an unknown composer id', () => {
    expect(selectComposer(state, 'other')).toBeNull();
  });

  it('defines the primary composer id', () => {
    expect(PRIMARY_COMPOSER_ID).toBe('primary');
  });
});

describe('getComposerStatePath', () => {
  it('points at the primary compose slice', () => {
    expect(getComposerStatePath(PRIMARY_COMPOSER_ID, 'scheduled')).toEqual(['compose', 'scheduled']);
  });

  it('points at a registry composer', () => {
    expect(getComposerStatePath('composer-a', 'scheduled')).toEqual(['composers', 'byId', 'composer-a', 'scheduled']);
  });
});
