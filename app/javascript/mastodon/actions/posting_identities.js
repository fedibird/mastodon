import { fromJS } from 'immutable';
import api from '../api';
import { me } from '../initial_state';
import { localPostingIdentityId } from '../posting_identity/identity';
import { targetComposerAction } from './composer';

export const POSTING_IDENTITIES_FETCH_REQUEST = 'POSTING_IDENTITIES_FETCH_REQUEST';
export const POSTING_IDENTITIES_FETCH_SUCCESS = 'POSTING_IDENTITIES_FETCH_SUCCESS';
export const POSTING_IDENTITIES_FETCH_FAIL = 'POSTING_IDENTITIES_FETCH_FAIL';
export const COMPOSER_SENDER_IDENTITY_SELECT = 'COMPOSER_SENDER_IDENTITY_SELECT';

const normalizeIdentity = identity => fromJS({
  id: identity.id,
  kind: identity.kind,
  provider: identity.provider,
  account: identity.account ? {
    id: String(identity.account.id),
    acct: identity.account.acct,
    display_name: identity.account.display_name,
    avatar: identity.account.avatar,
    avatar_static: identity.account.avatar_static,
  } : null,
  authorization: identity.authorization,
  capabilities: identity.capabilities || {},
});

const catalogIdentity = (state, identityId) => {
  const identities = state.getIn(['postingIdentities', 'identities']);

  if (!identities || !identities.find) {
    return null;
  }

  return identities.find(identity => identity.get('id') === identityId) || null;
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
        const identities = (data && Array.isArray(data.identities) ? data.identities : []).map(normalizeIdentity);

        dispatch({
          type: POSTING_IDENTITIES_FETCH_SUCCESS,
          defaultIdentityId: data && data.default_identity_id ? data.default_identity_id : null,
          identities,
          skipLoading: true,
        });

        return null;
      })
      .catch(error => {
        dispatch({
          type: POSTING_IDENTITIES_FETCH_FAIL,
          error,
          skipLoading: true,
          skipAlert: true,
        });

        return null;
      });
  };
}

export function syncComposerSenderIdentity(composerId) {
  return (dispatch, getState) => {
    const state = getState();
    const status = state.getIn(['postingIdentities', 'status']);

    if (!status || status === 'idle' || status === 'loading') {
      return null;
    }

    if (status === 'failed') {
      dispatch(targetComposerAction({ type: POSTING_IDENTITIES_FETCH_FAIL }, composerId));
      return null;
    }

    dispatch(targetComposerAction({
      type: POSTING_IDENTITIES_FETCH_SUCCESS,
      defaultIdentityId: state.getIn(['postingIdentities', 'defaultIdentityId']),
      identities: state.getIn(['postingIdentities', 'identities']),
    }, composerId));

    return null;
  };
}

// M1 applies only the authenticated local identity, and only when the
// catalog already grants it. Any other id is ignored.
export function selectComposerSenderIdentity(composerId, identityId) {
  return (dispatch, getState) => {
    const state = getState();
    const identity = catalogIdentity(state, identityId);
    const sessionId = localPostingIdentityId(me);

    if (!identity || identity.get('id') !== sessionId) {
      return null;
    }

    if (identity.get('authorization') !== 'ready' || identity.getIn(['capabilities', 'post']) !== 'supported') {
      return null;
    }

    if (String(identity.getIn(['account', 'id'])) !== String(me)) {
      return null;
    }

    dispatch(targetComposerAction({
      type: COMPOSER_SENDER_IDENTITY_SELECT,
      identityId: identity.get('id'),
    }, composerId));

    return null;
  };
}
