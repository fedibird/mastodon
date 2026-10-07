import {
  POSTING_CONTEXT_FETCH_FAIL,
  POSTING_CONTEXT_FETCH_REQUEST,
  POSTING_CONTEXT_FETCH_SUCCESS,
} from '../../actions/posting_contexts';
import postingContexts from '../posting_contexts';

const resolvedPayload = {
  schema_version: 1,
  account_id: '123',
  status: 'resolved',
  context: {
    key: 'builtin:fedibird-group:123',
    source: { id: 'builtin:fedibird-group', revision: 1 },
    managed: {
      hashtags: [],
      mentions: [
        {
          account_id: '123',
          acct: 'group',
          enforcement: 'required',
          rule_id: 'group-account-mention',
        },
      ],
    },
    requirements: {
      following_accounts: [
        {
          account_id: '123',
          acct: 'group',
          enforcement: 'required',
          rule_id: 'group-follow',
        },
      ],
    },
    constraints: {
      allowed_visibilities: ['public', 'unlisted'],
    },
  },
  discovery: {
    mechanism: 'built_in',
    adapter: 'fedibird_group',
    authority: 'server',
  },
};

describe('postingContexts', () => {
  it('moves an idle account to loading', () => {
    const state = postingContexts(undefined, {
      type: POSTING_CONTEXT_FETCH_REQUEST,
      accountId: '123',
    });

    expect(state.getIn(['123', 'status'])).toEqual('loading');
    expect(state.getIn(['123', 'context'])).toBeNull();
    expect(state.getIn(['123', 'error'])).toBeNull();
  });

  it('stores a resolved context', () => {
    const state = postingContexts(undefined, {
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '123',
      data: resolvedPayload,
    });

    expect(state.getIn(['123', 'status'])).toEqual('resolved');
    expect(state.getIn(['123', 'reason'])).toBeNull();
    expect(state.getIn(['123', 'error'])).toBeNull();
    expect(state.getIn(['123', 'context', 'managed', 'mentions', 0, 'accountId'])).toEqual('123');
    expect(state.getIn(['123', 'context', 'managed', 'mentions', 0, 'ruleId'])).toEqual('group-account-mention');
    expect(state.getIn(['123', 'context', 'requirements', 'followingAccounts', 0, 'ruleId'])).toEqual('group-follow');
    expect(state.getIn(['123', 'context', 'constraints', 'allowedVisibilities', 0])).toEqual('public');
    expect(state.getIn(['123', 'discovery', 'adapter'])).toEqual('fedibird_group');
    expect(state.getIn(['123', 'viewerEvidence'])).toBeNull();
  });

  it('stores viewer affiliation evidence without changing the resolved context', () => {
    const state = postingContexts(undefined, {
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '456',
      data: {
        ...resolvedPayload,
        account_id: '456',
        viewer_evidence: {
          affiliations: {
            source: 'fep-5219-affiliations',
            snapshot_status: 'fresh',
            fetched_at: '2026-10-07T01:23:45Z',
            relationships: [
              { relationship: 'admin', affiliation_uri: 'https://mitra.example/relationships/1' },
            ],
          },
        },
      },
    });

    expect(state.getIn(['456', 'status'])).toEqual('resolved');
    expect(state.getIn(['456', 'context', 'managed', 'mentions', 0, 'ruleId'])).toEqual('group-account-mention');
    expect(state.getIn(['456', 'viewerEvidence', 'affiliations', 'snapshotStatus'])).toEqual('fresh');
    expect(state.getIn(['456', 'viewerEvidence', 'affiliations', 'relationships', 0, 'relationship'])).toEqual('admin');
    expect(state.getIn(['456', 'viewerEvidence', 'affiliations', 'relationships', 0, 'affiliationUri'])).toEqual('https://mitra.example/relationships/1');
  });

  it('stores unsupported and not_applicable results without a context', () => {
    const unsupported = postingContexts(undefined, {
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '456',
      data: {
        schema_version: 1,
        account_id: '456',
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: null,
        discovery: { mechanism: null, adapter: null, authority: null },
      },
    });
    const notApplicable = postingContexts(unsupported, {
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '789',
      data: {
        schema_version: 1,
        account_id: '789',
        status: 'not_applicable',
        reason: 'not_group',
        context: null,
        discovery: { mechanism: null, adapter: null, authority: null },
      },
    });

    expect(notApplicable.getIn(['456', 'status'])).toEqual('unsupported');
    expect(notApplicable.getIn(['456', 'context'])).toBeNull();
    expect(notApplicable.getIn(['456', 'reason'])).toEqual('no_supported_adapter');
    expect(notApplicable.getIn(['789', 'status'])).toEqual('not_applicable');
    expect(notApplicable.getIn(['789', 'context'])).toBeNull();
    expect(notApplicable.getIn(['789', 'reason'])).toEqual('not_group');
  });

  it('records a fetch failure without a context', () => {
    const loading = postingContexts(undefined, {
      type: POSTING_CONTEXT_FETCH_REQUEST,
      accountId: '123',
    });
    const failed = postingContexts(loading, {
      type: POSTING_CONTEXT_FETCH_FAIL,
      accountId: '123',
      error: new Error('offline'),
    });

    expect(failed.getIn(['123', 'status'])).toEqual('error');
    expect(failed.getIn(['123', 'context'])).toBeNull();
    expect(failed.getIn(['123', 'error'])).toBe(true);
  });

  it('keeps a late result on the account it belongs to', () => {
    const resolved = postingContexts(undefined, {
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '123',
      data: resolvedPayload,
    });
    const next = postingContexts(resolved, {
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '456',
      data: {
        schema_version: 1,
        account_id: '456',
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: null,
        discovery: { mechanism: null, adapter: null, authority: null },
      },
    });

    expect(next.getIn(['123', 'status'])).toEqual('resolved');
    expect(next.getIn(['123', 'context', 'key'])).toEqual('builtin:fedibird-group:123');
    expect(next.getIn(['456', 'status'])).toEqual('unsupported');
  });
});
