import { isAdministrator, me } from '../initial_state';
import { composerHasGroupDestination } from '../posting_identity/group_destination';
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

  const delegatedSender = typeof senderId === 'string' && senderId.startsWith('delegated:');

  if (!delegatedSender && sessionId && senderId !== sessionId) {
    return deny('mismatch');
  }

  if (!delegatedSender && !sessionId && senderId) {
    return deny('mismatch');
  }

  if (delegatedSender && (!isAdministrator || catalogStatus !== 'ready')) {
    return deny(catalogStatus === 'failed' ? 'failed' : 'unresolved');
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

    if (!capabilityAllows(identity, 'post')) {
      return deny('unsupported');
    }

    if (identity.get('kind') === 'delegated') {
      if (!isAdministrator || identity.get('provider') !== 'fedibird') {
        return deny('unsupported');
      }

      if (identity.get('id') !== senderId) {
        return deny('mismatch');
      }

      if (composer.get('in_reply_to') || composer.get('quote_from')) {
        return deny('reply');
      }

      if (composerHasGroupDestination(composer)) {
        return deny('group');
      }

      if (composer.get('scheduled') || composer.get('scheduled_status_id') || composer.get('expires')) {
        return deny('schedule');
      }

      if (composer.get('poll')) {
        return deny('poll');
      }

      if (composer.get('id')) {
        return deny('edit_bound');
      }

      const mediaSupported = capabilityAllows(identity, 'media');
      const attachments = composer.get('media_attachments');
      const pendingMedia = attachments.size > 0 || composer.get('is_uploading') || composer.get('is_processing') || composer.get('pending_media_attachments') > 0;

      if (attachments.some(item => item.get('type') && item.get('type') !== 'image')) {
        return { canSend: false, canUpload: false, reason: 'media_type', stillImagesOnly: true };
      }

      if (pendingMedia && !mediaSupported) {
        return { canSend: false, canUpload: false, reason: 'media', stillImagesOnly: false };
      }

      if (composer.get('is_uploading') || composer.get('is_processing') || composer.get('pending_media_attachments') > 0) {
        return { canSend: false, canUpload: mediaSupported, reason: 'processing', stillImagesOnly: mediaSupported };
      }

      return {
        canSend: true,
        canUpload: mediaSupported,
        reason: mediaSupported ? null : 'media',
        stillImagesOnly: mediaSupported,
      };
    }

    if (identity.get('id') !== (senderId || sessionId)) {
      return deny('mismatch');
    }

    if (me && String(identity.getIn(['account', 'id'])) !== String(me)) {
      return deny('mismatch');
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

  if (decision.canUpload === true) {
    return {
      canUpload: true,
      reason: null,
      stillImagesOnly: decision.stillImagesOnly === true,
    };
  }

  return {
    canUpload: false,
    reason: decision.reason || 'unauthorized',
    stillImagesOnly: false,
  };
};
