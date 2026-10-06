import { Map as ImmutableMap } from 'immutable';
import { buildFedibirdGroupPostingContext, isFedibirdLocalGroup } from '../fedibird_group';

describe('buildFedibirdGroupPostingContext', () => {
  const localGroup = ImmutableMap({ id: '123', acct: 'group', username: 'group', group: true });
  const remoteGroup = ImmutableMap({ id: '123', acct: 'group@example.com', username: 'group', group: true });

  it('describes a local Fedibird group without snapshotting follow state', () => {
    const context = buildFedibirdGroupPostingContext(localGroup);

    expect(isFedibirdLocalGroup(localGroup)).toBe(true);
    expect(context.key).toEqual('builtin:fedibird-group:123');
    expect(context.source).toEqual({ id: 'builtin:fedibird-group', revision: 1 });
    expect(context.managed.mentions).toEqual([
      { accountId: '123', acct: 'group', enforcement: 'required', ruleId: 'group-account-mention' },
    ]);
    expect(context.requirements.followingAccounts).toEqual([
      { accountId: '123', acct: 'group', enforcement: 'required', ruleId: 'group-follow' },
    ]);
    expect(context.constraints.allowedVisibilities).toEqual(['public', 'unlisted']);
    expect(context.requirements.followingAccounts[0].following).toBeUndefined();
  });

  it('does not infer posting semantics for a remote group', () => {
    expect(isFedibirdLocalGroup(remoteGroup)).toBe(false);
    expect(buildFedibirdGroupPostingContext(remoteGroup)).toBeNull();
    expect(buildFedibirdGroupPostingContext(ImmutableMap({ id: '1', acct: 'alice', username: 'alice', group: false }))).toBeNull();
  });
});
