import { Map as ImmutableMap, Set as ImmutableSet } from 'immutable';
import { composerActivityPubAudienceAccountId, composerActivityPubAudienceAllowedVisibilities } from '../protocol';

const composer = (values = {}) => ImmutableMap({
  id: null,
  scheduled_status_id: null,
  draft_audience_account_id: null,
  context: ImmutableMap({
    protocol: ImmutableMap({
      activityPub: ImmutableMap({
        audience: ImmutableMap({
          accountId: '456',
        }),
      }),
    }),
  }),
}).merge(values);

describe('composerActivityPubAudienceAccountId', () => {
  it('uses the posting context audience for a new post', () => {
    expect(composerActivityPubAudienceAccountId(composer())).toEqual('456');
  });

  it('returns null when the context has no audience', () => {
    const state = composer().setIn(['context', 'protocol', 'activityPub', 'audience'], null);

    expect(composerActivityPubAudienceAccountId(state)).toBeNull();
  });

  it('omits a target while editing an existing status', () => {
    expect(composerActivityPubAudienceAccountId(composer({
      id: 's1',
      draft_audience_account_id: '456',
    }))).toBeNull();
  });

  it('keeps the retained scheduled target ahead of the current context', () => {
    const state = composer({
      scheduled_status_id: 'sched-1',
      draft_audience_account_id: '456',
    }).setIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'], '789');

    expect(composerActivityPubAudienceAccountId(state)).toEqual('456');
  });
});

describe('composerActivityPubAudienceAllowedVisibilities', () => {
  it('returns null while editing an existing status', () => {
    expect(composerActivityPubAudienceAllowedVisibilities(composer({
      id: 's1',
      draft_audience_account_id: '456',
    }))).toBeNull();
  });

  it('limits a scheduled draft to public and unlisted when it retains an audience', () => {
    const state = composer({
      scheduled_status_id: 'sched-1',
      draft_audience_account_id: '456',
    }).setIn(['context', 'constraints', 'allowedVisibilities'], ImmutableSet(['private']));

    expect(composerActivityPubAudienceAllowedVisibilities(state).toArray()).toEqual(['public', 'unlisted']);
  });

  it('returns null for a scheduled draft without a retained audience', () => {
    expect(composerActivityPubAudienceAllowedVisibilities(composer({
      scheduled_status_id: 'sched-1',
    }))).toBeNull();
  });

  it('uses the context constraint for a new post with an audience', () => {
    const allowed = ImmutableSet(['public', 'unlisted']);
    const state = composer().setIn(['context', 'constraints', 'allowedVisibilities'], allowed);

    expect(composerActivityPubAudienceAllowedVisibilities(state)).toBe(allowed);
  });
});
