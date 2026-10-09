import { isAdministrator, me } from '../initial_state';
import { sessionPostingIdentityId } from '../posting_identity/identity';
import { selectComposer } from './composer';

const deny = reason => ({ canSend: false, canUpload: false, reason });

const findIdentity = (state, identityId) => {
  const identities = state.getIn(['postingIdentities', 'identities']);

  if (!identities || !identities.find || !identityId) {
    return null;
  }

  return identities.find(identity => identity.get('id') === identityId) || null;
};

export const selectPostingIdentityCatalog = state => state.get('postingIdentities', null);

export const selectComposerSenderIdentity = (state, composerId) => {
  const composer = selectComposer(state, composerId);

  if (!composer) {
    return null;
  }

  const sender = composer.get('senderIdentity');

  if (!sender) {
    return null;
  }

  const listed = findIdentity(state, sender.get('id'));

  if (!listed) {
    return sender;
  }

  return sender.merge({
    kind: listed.get('kind'),
    provider: listed.get('provider'),
    authorization: listed.get('authorization'),
    account: listed.get('account'),
    capabilities: listed.get('capabilities'),
  });
};

const capabilityAllows = (identity, name) => (
  !identity || identity.getIn(['capabilities', name]) === 'supported'
);

export const selectComposerCanSendAsIdentity = (state, composerId) => {
  const composer = selectComposer(state, composerId);

  if (!composer) {
    return deny('missing');
  }

  const sender = composer.get('senderIdentity');
  const senderId = sender ? sender.get('id') : null;
  const senderStatus = sender ? sender.get('status') : null;
  const sessionId = sessionPostingIdentityId();
  const catalogStatus = state.getIn(['postingIdentities', 'status'], 'idle');
  const confirmedIdentityId = state.getIn(['postingIdentities', 'confirmedIdentityId'], null);

  if (!sender || senderStatus !== 'ready') {
    return deny(senderStatus || 'unresolved');
  }

  if (sessionId && senderId !== sessionId) {
    return deny('mismatch');
  }

  if (!sessionId && senderId) {
    return deny('mismatch');
  }

  // Administrators post only after the catalog confirms the signed-in
  // account. Idle, loading, and failed are not permission to send.
  // A non-administrator does not fetch the catalog, so an idle catalog
  // still uses the existing session.
  if (isAdministrator && catalogStatus !== 'ready') {
    return deny(catalogStatus || 'idle');
  }

  if (catalogStatus === 'failed') {
    return deny('failed');
  }

  if (catalogStatus === 'loading' && confirmedIdentityId !== sessionId) {
    return deny('unresolved');
  }

  if (catalogStatus === 'ready') {
    const identity = findIdentity(state, senderId || sessionId);

    if (!identity) {
      return deny('unregistered');
    }

    if (identity.get('authorization') !== 'ready') {
      return deny('unauthorized');
    }

    if (identity.get('id') !== (senderId || sessionId)) {
      return deny('mismatch');
    }

    if (me && String(identity.getIn(['account', 'id'])) !== String(me)) {
      return deny('mismatch');
    }

    if (!capabilityAllows(identity, 'post')) {
      return deny('unsupported');
    }

    if (composer.get('in_reply_to') && !capabilityAllows(identity, 'reply')) {
      return deny('reply');
    }

    if (composer.getIn(['surface', 'kind']) === 'group' && !capabilityAllows(identity, 'group')) {
      return deny('group');
    }

    if ((composer.get('scheduled') || composer.get('scheduled_status_id')) && !capabilityAllows(identity, 'schedule')) {
      return deny('schedule');
    }

    return {
      canSend: true,
      canUpload: capabilityAllows(identity, 'media'),
      reason: capabilityAllows(identity, 'media') ? null : 'media',
    };
  }

  return { canSend: true, canUpload: true, reason: null };
};

export const selectComposerCanUploadAsIdentity = (state, composerId) => {
  const decision = selectComposerCanSendAsIdentity(state, composerId);

  if (!decision.canSend || decision.canUpload === false) {
    return {
      canUpload: false,
      reason: decision.reason || 'unauthorized',
    };
  }

  return { canUpload: true, reason: null };
};
