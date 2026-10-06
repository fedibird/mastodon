import { Map as ImmutableMap, Set as ImmutableSet } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import composer from '../../reducers/composer';
import { buildFedibirdGroupPostingContext } from '../fedibird_group';
import { selectComposerPostingContextCompliance } from '../compliance';

const localGroup = ImmutableMap({ id: '123', acct: 'group', username: 'group', group: true });

const groupState = ({ privacy = 'public', prohibited = [], relationship }) => {
  let composerState = composer(undefined, {
    type: 'COMPOSER_CONTEXT_APPLY',
    postingContext: buildFedibirdGroupPostingContext(localGroup),
  });

  composerState = composer(composerState, {
    type: 'COMPOSE_VISIBILITY_CHANGE',
    value: privacy,
  });

  if (prohibited.length > 0) {
    composerState = composerState.set('prohibited_visibilities', ImmutableSet(prohibited));
  }

  const relationships = relationship ? ImmutableMap({ '123': ImmutableMap(relationship) }) : ImmutableMap();

  return ImmutableMap({
    compose: composerState,
    relationships,
  });
};

describe('selectComposerPostingContextCompliance', () => {
  it('rejects a visibility outside the group constraint', () => {
    const compliance = selectComposerPostingContextCompliance(groupState({ privacy: 'private', relationship: { following: true } }), 'primary');

    expect(compliance.valid).toBe(false);
    expect(compliance.visibility.valid).toBe(false);
    expect(compliance.visibility.allowed).toEqual(['public', 'unlisted']);
  });

  it('intersects context visibilities with base prohibitions', () => {
    const unlistedOnly = selectComposerPostingContextCompliance(groupState({
      privacy: 'unlisted',
      prohibited: ['public'],
      relationship: { following: true },
    }), 'primary');
    const none = selectComposerPostingContextCompliance(groupState({
      privacy: 'public',
      prohibited: ['public', 'unlisted'],
      relationship: { following: true },
    }), 'primary');

    expect(unlistedOnly.visibility.available).toEqual(['unlisted']);
    expect(unlistedOnly.valid).toBe(true);
    expect(none.visibility.available).toEqual([]);
    expect(none.valid).toBe(false);
  });

  it('reads follow state live from relationships', () => {
    const unknown = selectComposerPostingContextCompliance(groupState({ privacy: 'public' }), 'primary');
    const notFollowing = selectComposerPostingContextCompliance(groupState({
      privacy: 'public',
      relationship: { following: false, requested: false },
    }), 'primary');
    const requested = selectComposerPostingContextCompliance(groupState({
      privacy: 'public',
      relationship: { following: false, requested: true },
    }), 'primary');
    const satisfied = selectComposerPostingContextCompliance(groupState({
      privacy: 'public',
      relationship: { following: true, requested: false },
    }), 'primary');

    expect(unknown.followingAccounts[0].status).toEqual('unknown');
    expect(unknown.valid).toBe(false);
    expect(notFollowing.followingAccounts[0].status).toEqual('not_following');
    expect(notFollowing.valid).toBe(false);
    expect(requested.followingAccounts[0].status).toEqual('requested');
    expect(requested.valid).toBe(false);
    expect(satisfied.followingAccounts[0]).toEqual({ accountId: '123', acct: 'group', status: 'satisfied' });
    expect(satisfied.valid).toBe(true);
  });

  it('treats a composer without posting requirements as compliant', () => {
    const compliance = selectComposerPostingContextCompliance(ImmutableMap({
      compose: composer(undefined, { type: '@@INIT' }),
    }), 'primary');

    expect(compliance.valid).toBe(true);
    expect(compliance.visibility.allowed).toBeNull();
    expect(compliance.followingAccounts).toEqual([]);
  });
});
