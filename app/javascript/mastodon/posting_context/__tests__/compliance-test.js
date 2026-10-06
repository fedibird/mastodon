import { Map as ImmutableMap, Set as ImmutableSet } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import composer from '../../reducers/composer';
import { selectComposerPostingContextCompliance } from '../compliance';
import { groupPostingContext } from './group_context_fixture';

const groupState = ({ privacy = 'public', prohibited = [], relationship }) => {
  let composerState = composer(undefined, {
    type: 'COMPOSER_CONTEXT_APPLY',
    postingContext: groupPostingContext,
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

  it('treats an existing or scheduled edit as compliant without clearing context', () => {
    const draft = groupState({ privacy: 'private' });
    const editing = draft.setIn(['compose', 'id'], 'status-9');
    const scheduled = draft.setIn(['compose', 'scheduled_status_id'], 'sched-1');

    [editing, scheduled].forEach(state => {
      const compliance = selectComposerPostingContextCompliance(state, 'primary');

      expect(compliance.valid).toBe(true);
      expect(compliance.visibility).toEqual({ valid: true, allowed: null, available: null });
      expect(compliance.followingAccounts).toEqual([]);
      expect(state.getIn(['compose', 'context', 'key'])).toEqual('builtin:fedibird-group:123');
      expect(state.getIn(['compose', 'context', 'managed', 'mentions', 0, 'acct'])).toEqual('group');
      expect(state.getIn(['compose', 'context', 'requirements', 'followingAccounts', 0, 'accountId'])).toEqual('123');
      expect(state.getIn(['compose', 'context', 'constraints', 'allowedVisibilities']).includes('private')).toBe(false);
      expect(state.getIn(['compose', 'context', 'constraints', 'allowedVisibilities']).includes('public')).toBe(true);
    });

    expect(selectComposerPostingContextCompliance(draft, 'primary').valid).toBe(false);
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
