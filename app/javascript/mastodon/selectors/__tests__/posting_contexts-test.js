import { fromJS } from 'immutable';

import { selectPostingContextDiscovery, selectPostingContextViewerEvidence } from '../posting_contexts';

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
