import { fromJS } from 'immutable';

import { groupPostingContext } from '../../../posting_context/fixtures/group_context_fixture';
import {
  groupAccountBecameAvailable,
  shouldFetchGroupPostingContext,
} from '../portable_composer_eligibility';

jest.mock('mastodon/initial_state', () => ({
  isAdministrator: false,
}));

const localGroup = fromJS({
  id: '123',
  acct: 'group',
  group: true,
});

const discoveryRecord = (status, context = groupPostingContext) => fromJS({
  status,
  context: context ? fromJS(context) : null,
  discovery: status === 'resolved' ? {
    mechanism: 'built_in',
    adapter: 'fedibird_group',
    authority: 'server',
  } : {
    mechanism: null,
    adapter: null,
    authority: null,
  },
});

describe('shouldFetchGroupPostingContext for general users', () => {
  it('starts discovery from the timeline id before the account is in Redux', () => {
    expect(shouldFetchGroupPostingContext({
      composerVisible: false,
      discoveryRecord: null,
      account: null,
      groupId: '123',
    })).toBe(true);
  });

  it('does not refetch while discovery is in flight or already resolved for Fedibird', () => {
    expect(shouldFetchGroupPostingContext({
      composerVisible: false,
      discoveryRecord: discoveryRecord('loading'),
      account: null,
      groupId: '123',
    })).toBe(false);

    expect(shouldFetchGroupPostingContext({
      composerVisible: true,
      discoveryRecord: discoveryRecord('resolved'),
      account: null,
      groupId: '123',
    })).toBe(false);
  });

  it('detects when the account record becomes available', () => {
    expect(groupAccountBecameAvailable(null, localGroup)).toBe(true);
    expect(groupAccountBecameAvailable(localGroup, localGroup)).toBe(false);
  });
});
