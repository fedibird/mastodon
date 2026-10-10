import { List as ImmutableList, fromJS } from 'immutable';
import api from '../api';
import { normalizePostingIdentity, sessionPostingIdentityId } from '../posting_identity/identity';
import { composerSenderSwitchDraft, resolveSenderIdentitySwitch } from '../posting_identity/switch_resolver';
import { selectComposer } from '../selectors/composer';
import { selectPostingContextViewerEvidence } from '../selectors/posting_contexts';
import uuid from '../uuid';
import { COMPOSER_SENDER_IDENTITY_SELECT, targetComposerAction } from './composer';

export const POSTING_IDENTITIES_FETCH_REQUEST = 'POSTING_IDENTITIES_FETCH_REQUEST';
export const POSTING_IDENTITIES_FETCH_SUCCESS = 'POSTING_IDENTITIES_FETCH_SUCCESS';
export const POSTING_IDENTITIES_FETCH_FAIL = 'POSTING_IDENTITIES_FETCH_FAIL';

const findListedIdentity = (state, identityId) => {
  const identities = state.getIn(['postingIdentities', 'identities']);

  if (!identities || !identities.find) {
    return null;
  }

  return identities.find(identity => identity.get('id') === String(identityId)) || null;
};

const identityRecord = listed => {
  if (!listed) {
    return null;
  }

  return {
    id: listed.get('id'),
    kind: listed.get('kind'),
    provider: listed.get('provider'),
    authorization: listed.get('authorization'),
    capabilities: listed.get('capabilities') ? listed.get('capabilities').toJS() : {},
    registered: true,
  };
};

export function fetchPostingIdentities({ force = false } = {}) {
  return (dispatch, getState) => {
    const status = getState().getIn(['postingIdentities', 'status']);

    if (status === 'loading' || (!force && (status === 'ready' || status === 'failed'))) {
      return Promise.resolve();
    }

    dispatch({ type: POSTING_IDENTITIES_FETCH_REQUEST, skipLoading: true });

    return api(getState)
      .get('/api/v1/fedibird/posting_identities')
      .then(({ data }) => {
        const identities = ImmutableList((data.identities || []).map(identity => fromJS(normalizePostingIdentity(identity))));
        const sessionId = sessionPostingIdentityId();
        const confirmed = identities.find(identity => (
          identity.get('id') === sessionId && identity.get('authorization') === 'ready'
        ));

        dispatch({
          type: POSTING_IDENTITIES_FETCH_SUCCESS,
          defaultIdentityId: data.default_identity_id ? String(data.default_identity_id) : null,
          identities,
          confirmedIdentityId: confirmed ? confirmed.get('id') : null,
          skipLoading: true,
        });
      })
      .catch(error => {
        dispatch({
          type: POSTING_IDENTITIES_FETCH_FAIL,
          error,
          skipLoading: true,
          skipAlert: true,
        });
      });
  };
}

export function selectComposerSenderIdentity(composerId, identityId, { confirmed = false } = {}) {
  return (dispatch, getState) => {
    const state = getState();
    const composer = selectComposer(state, composerId);

    if (!composer) {
      return null;
    }

    const surface = composer.get('surface');
    const groupId = surface && surface.get('kind') === 'group' ? surface.get('key') : null;
    const viewerEvidence = groupId ? selectPostingContextViewerEvidence(state, groupId) : null;
    const listed = findListedIdentity(state, identityId);
    const decision = resolveSenderIdentitySwitch({
      fromIdentityId: composer.getIn(['senderIdentity', 'id']),
      toIdentity: listed ? identityRecord(listed) : { id: identityId ? String(identityId) : null, registered: false },
      draft: composerSenderSwitchDraft(composer, viewerEvidence),
      sessionIdentityId: sessionPostingIdentityId(),
      nextIdempotencyKey: uuid(),
      switching: composer.getIn(['senderIdentity', 'status']) === 'switching',
      confirmed,
    });

    return dispatch(targetComposerAction({
      type: COMPOSER_SENDER_IDENTITY_SELECT,
      identityId: identityId ? String(identityId) : null,
      decision,
    }, composerId));
  };
}
