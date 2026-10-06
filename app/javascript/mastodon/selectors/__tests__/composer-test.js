import { List as ImmutableList, Set as ImmutableSet, fromJS } from 'immutable';

import { PRIMARY_COMPOSER_ID, getComposerStatePath, selectComposer, selectPortableComposerSeed } from '../composer';

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

describe('selectPortableComposerSeed', () => {
  const primary = fromJS({
    text: 'PRIMARY DRAFT',
    media_attachments: [{ id: 'm1' }],
    in_reply_to: 'status-1',
    privacy: 'direct',
    idempotencyKey: 'primary-key',
    default_privacy: 'private',
    default_sensitive: true,
    default_language: 'ja',
    default_searchability: 'private',
    default_expires_in: 3600,
    default_expires_action: 'delete',
    poll_max_options: 4,
    tagHistory: ['fedibird'],
  }).set('prohibited_visibilities', ImmutableSet(['direct']))
    .set('prohibited_words', ImmutableSet(['nope']));

  const seededState = fromJS({ compose: {} }).set('compose', primary);

  it('copies only composer defaults from the primary composer', () => {
    const seed = selectPortableComposerSeed(seededState);

    expect(seed.get('default_privacy')).toEqual('private');
    expect(seed.get('default_sensitive')).toBe(true);
    expect(seed.get('default_language')).toEqual('ja');
    expect(seed.get('default_searchability')).toEqual('private');
    expect(seed.get('default_expires_in')).toEqual(3600);
    expect(seed.get('default_expires_action')).toEqual('delete');
    expect(seed.get('poll_max_options')).toEqual(4);
    expect(seed.get('prohibited_visibilities')).toBe(primary.get('prohibited_visibilities'));
    expect(seed.get('prohibited_words')).toBe(primary.get('prohibited_words'));
    expect(seed.get('tagHistory')).toEqual(ImmutableList(['fedibird']));
    expect(seed.has('text')).toBe(false);
    expect(seed.has('media_attachments')).toBe(false);
    expect(seed.has('in_reply_to')).toBe(false);
    expect(seed.has('privacy')).toBe(false);
    expect(seed.has('idempotencyKey')).toBe(false);
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
