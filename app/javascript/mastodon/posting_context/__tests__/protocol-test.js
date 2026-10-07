import { Map as ImmutableMap } from 'immutable';
import { composerActivityPubAudienceAccountId } from '../protocol';

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
