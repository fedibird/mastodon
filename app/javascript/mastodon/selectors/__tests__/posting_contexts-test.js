import { fromJS } from 'immutable';

import { selectPostingContextCreatePermissionEvidence, selectPostingContextDiscovery, selectPostingContextViewPermissionEvidence, selectPostingContextViewerEvidence } from '../posting_contexts';

const state = fromJS({
  posting_contexts: {
    '123': {
      status: 'resolved',
      viewerEvidence: {
        affiliations: {
          source: 'fep-5219-affiliations',
          snapshotStatus: 'fresh',
          fetchedAt: '2026-10-07T01:23:45Z',
          relationships: [
            { relationship: 'admin', affiliationUri: 'https://mitra.example/relationships/1' },
          ],
        },
        permissions: {
          create: {
            status: 'allowed',
            source: 'fep-5219',
            viaRelationship: 'trusted-poster',
            authority: 'protocol',
          },
          view: {
            status: 'unknown',
            source: 'fep-5219',
            viaRelationship: null,
            authority: 'protocol',
          },
        },
      },
    },
    '456': {
      status: 'unsupported',
      viewerEvidence: null,
    },
  },
});

describe('selectPostingContextViewerEvidence', () => {
  it('returns the immutable viewer evidence stored for the account', () => {
    const evidence = selectPostingContextViewerEvidence(state, '123');

    expect(evidence).toBe(selectPostingContextDiscovery(state, 123).get('viewerEvidence'));
    expect(evidence.getIn(['affiliations', 'snapshotStatus'])).toEqual('fresh');
    expect(evidence.getIn(['affiliations', 'relationships', 0, 'relationship'])).toEqual('admin');
  });

  it('returns null when the account has no evidence', () => {
    expect(selectPostingContextViewerEvidence(state, '456')).toBeNull();
    expect(selectPostingContextViewerEvidence(state, 'missing')).toBeNull();
    expect(selectPostingContextViewerEvidence(null, '123')).toBeNull();
  });
});

describe('selectPostingContextCreatePermissionEvidence', () => {
  it('returns the immutable create permission for the account', () => {
    const permission = selectPostingContextCreatePermissionEvidence(state, '123');

    expect(permission).toBe(selectPostingContextViewerEvidence(state, '123').getIn(['permissions', 'create']));
    expect(permission.get('status')).toEqual('allowed');
    expect(permission.get('viaRelationship')).toEqual('trusted-poster');
    expect(permission.get('authority')).toEqual('protocol');
  });

  it('returns null when permission evidence is absent', () => {
    const legacy = state.setIn(['posting_contexts', '123', 'viewerEvidence', 'permissions'], null);

    expect(selectPostingContextCreatePermissionEvidence(legacy, '123')).toBeNull();
    expect(selectPostingContextCreatePermissionEvidence(state, '456')).toBeNull();
    expect(selectPostingContextCreatePermissionEvidence(state, 'missing')).toBeNull();
    expect(selectPostingContextCreatePermissionEvidence(null, '123')).toBeNull();
  });
});

describe('selectPostingContextViewPermissionEvidence', () => {
  it('returns the immutable view permission for the account', () => {
    const permission = selectPostingContextViewPermissionEvidence(state, '123');

    expect(permission.get('status')).toEqual('unknown');
    expect(permission.get('viaRelationship')).toBeNull();
  });

  it('returns null when view evidence is absent', () => {
    expect(selectPostingContextViewPermissionEvidence(state, '456')).toBeNull();
    expect(selectPostingContextViewPermissionEvidence(null, '123')).toBeNull();
  });
});
