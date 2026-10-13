import { List as ImmutableList, fromJS } from 'immutable';
import api from '../api';
import { materializeComposerText } from '../posting_context/materialize';
import { consistentLocalFedibirdGroup } from '../posting_identity/group_destination';
import { normalizePostingIdentity, sessionPostingIdentityId } from '../posting_identity/identity';
import { composerInteractionInputKey, composerInteractionSpoilerText } from '../posting_identity/interaction_input';
import { composerSenderSwitchDraft, resolveSenderIdentitySwitch } from '../posting_identity/switch_resolver';
import { selectComposer } from '../selectors/composer';
import { selectPostingIdentityDelegationId } from '../selectors/posting_identities';
import { selectPostingContextViewerEvidence } from '../selectors/posting_contexts';
import { fetchPostingContext } from './posting_contexts';
import uuid from '../uuid';
import { COMPOSER_INTERACTION_CHECK_FAIL, COMPOSER_INTERACTION_CHECK_REQUEST, COMPOSER_INTERACTION_CHECK_SUCCESS, COMPOSER_SENDER_IDENTITY_SELECT, targetComposerAction } from './composer';

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

    const selected = dispatch(targetComposerAction({
      type: COMPOSER_SENDER_IDENTITY_SELECT,
      identityId: identityId ? String(identityId) : null,
      decision,
    }, composerId));

    if (decision.effectsApplied && (decision.mustRevalidateReply || decision.mustRevalidateQuote || decision.mustRevalidateGroup)) {
      dispatch(scheduleComposerInteractionCheck(composerId));
    }

    if (decision.effectsApplied && decision.refreshGroupDiscovery) {
      const next = selectComposer(getState(), composerId);
      const accountId = next && (next.get('posting_context_account_id') || next.getIn(['context', 'resolvedAccountId']));

      if (accountId) {
        dispatch(fetchPostingContext(accountId, {
          force: true,
          identityId: decision.toIdentityId,
          delegationId: selectPostingIdentityDelegationId(getState(), decision.toIdentityId),
        }));
      }
    }

    return selected;
  };
}

export const INTERACTION_CHECK_DELAY = 300;

const interactionTimers = new Map();
const interactionSerial = new Map();

const clearInteractionTimer = composerId => {
  const timer = interactionTimers.get(composerId);

  if (timer) {
    clearTimeout(timer);
    interactionTimers.delete(composerId);
  }
};

const interactionNeeded = composer => {
  if (!composer) {
    return false;
  }

  const identityId = composer.getIn(['senderIdentity', 'id']);
  const delegated = typeof identityId === 'string' && identityId.startsWith('delegated:');
  const group = consistentLocalFedibirdGroup(composer) && !composer.get('in_reply_to') && !composer.get('quote_from');

  return delegated && Boolean(composer.get('in_reply_to') || composer.get('quote_from') || group);
};

const nextInteractionRequestId = composerId => {
  const next = (interactionSerial.get(composerId) || 0) + 1;

  interactionSerial.set(composerId, next);

  return next;
};

export function cancelComposerInteractionChecks () {
  interactionTimers.forEach(timer => clearTimeout(timer));
  interactionTimers.clear();
  interactionSerial.clear();
}

export function scheduleComposerInteractionCheck (composerId) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);

    clearInteractionTimer(composerId);

    if (!interactionNeeded(composer)) {
      return;
    }

    const timer = setTimeout(() => {
      interactionTimers.delete(composerId);
      dispatch(validateComposerInteraction(composerId));
    }, INTERACTION_CHECK_DELAY);

    interactionTimers.set(composerId, timer);
  };
}

export function retryComposerInteraction (composerId) {
  return (dispatch) => {
    clearInteractionTimer(composerId);

    return dispatch(validateComposerInteraction(composerId));
  };
}

export function validateComposerInteraction(composerId) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);

    if (!interactionNeeded(composer)) {
      return Promise.resolve();
    }

    const identityId = composer.getIn(['senderIdentity', 'id']);
    const epoch = Number(composer.getIn(['senderIdentity', 'changeEpoch'])) || 0;
    const replyId = composer.get('in_reply_to') || null;
    const quoteId = composer.get('quote_from') || null;
    const delegationId = selectPostingIdentityDelegationId(getState(), identityId);
    const inputKey = composerInteractionInputKey(composer);
    const localGroup = consistentLocalFedibirdGroup(composer);
    const snapshot = { identityId, epoch, delegationId, inputKey, requestId: nextInteractionRequestId(composerId) };
    const payload = {
      posting_identity_id: identityId,
      in_reply_to_id: replyId,
      quote_id: quoteId,
      visibility: composer.get('privacy'),
      status: materializeComposerText(composer),
      spoiler_text: composerInteractionSpoilerText(composer),
    };

    if (localGroup) {
      payload.posting_context_account_id = composer.get('posting_context_account_id');
      payload.posting_context_key = composer.getIn(['context', 'key']);
      payload.posting_context_revision = composer.getIn(['context', 'source', 'revision']);
    }

    dispatch(targetComposerAction({
      type: COMPOSER_INTERACTION_CHECK_REQUEST,
      ...snapshot,
      skipLoading: true,
    }, composerId));

    return api(getState)
      .post('/api/v1/fedibird/posting_identities/interaction', payload)
      .then(() => {
        dispatch(targetComposerAction({
          type: COMPOSER_INTERACTION_CHECK_SUCCESS,
          ...snapshot,
          skipLoading: true,
        }, composerId));
      })
      .catch(() => {
        dispatch(targetComposerAction({
          type: COMPOSER_INTERACTION_CHECK_FAIL,
          ...snapshot,
          skipLoading: true,
          skipAlert: true,
        }, composerId));
      });
  };
}
