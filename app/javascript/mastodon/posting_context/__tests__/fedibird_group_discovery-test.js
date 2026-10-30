import { fromJS } from 'immutable';

import { groupPostingContext } from '../fixtures/group_context_fixture';
import {
  isLocalFedibirdGroupAccount,
  isPublicFedibirdGroupTimeline,
  isResolvedFedibirdGroupDiscovery,
} from '../fedibird_group_discovery';

const localGroup = fromJS({
  id: '123',
  acct: 'group',
  group: true,
});

const remoteGroup = fromJS({
  id: '456',
  acct: 'group@example.com',
  group: true,
});

const discoveryRecord = (status, context = groupPostingContext, discovery = {
  mechanism: 'built_in',
  adapter: 'fedibird_group',
  authority: 'server',
}) => fromJS({
  status,
  context: context ? fromJS(context) : null,
  discovery,
});

describe('fedibird_group_discovery', () => {
  it('accepts a resolved local Fedibird group discovery', () => {
    expect(isResolvedFedibirdGroupDiscovery(discoveryRecord('resolved'), '123')).toBe(true);
    expect(isPublicFedibirdGroupTimeline(discoveryRecord('resolved'), localGroup)).toBe(true);
  });

  it('rejects discovery when the context key does not match the timeline account', () => {
    const record = discoveryRecord('resolved', {
      ...groupPostingContext,
      key: 'builtin:fedibird-group:999',
    });

    expect(isResolvedFedibirdGroupDiscovery(record, '123')).toBe(false);
  });

  it('rejects remote-looking groups for the public Fedibird timeline gate', () => {
    const record = discoveryRecord('resolved', {
      ...groupPostingContext,
      key: 'builtin:fedibird-group:456',
      managed: {
        hashtags: [],
        mentions: [{
          accountId: '456',
          acct: 'group@example.com',
          enforcement: 'required',
          ruleId: 'group-account-mention',
        }],
      },
      requirements: {
        followingAccounts: [{
          accountId: '456',
          acct: 'group@example.com',
          enforcement: 'required',
          ruleId: 'group-follow',
        }],
      },
    });

    expect(isResolvedFedibirdGroupDiscovery(record, '456')).toBe(true);
    expect(isPublicFedibirdGroupTimeline(record, remoteGroup)).toBe(false);
    expect(isLocalFedibirdGroupAccount(remoteGroup)).toBe(false);
  });

  it('rejects non-Fedibird adapters and unresolved discovery', () => {
    expect(isResolvedFedibirdGroupDiscovery(discoveryRecord('loading'), '123')).toBe(false);
    expect(isResolvedFedibirdGroupDiscovery(discoveryRecord('unsupported'), '123')).toBe(false);
    expect(isResolvedFedibirdGroupDiscovery(discoveryRecord('resolved', groupPostingContext, {
      mechanism: 'protocol',
      adapter: 'mitra_group',
      authority: 'protocol',
    }), '123')).toBe(false);
  });
});
