import { ENABLED_SENDER_KINDS, ENABLED_SENDER_PROVIDERS } from './identity';
import { applyPostingStylePrecedence } from './style_precedence';

const mediaOwner = (item, fromIdentityId) => (
  item && item.ownerIdentityId ? item.ownerIdentityId : fromIdentityId
);

// Pure description of a sender change. M1 permits a change only when the
// target is the signed-in local account. The plan still says what a later
// change must do, and callers must not apply a plan that is not permitted.
export function resolveSenderIdentitySwitch({
  fromIdentityId = null,
  toIdentity = null,
  draft = {},
  sessionIdentityId = null,
  nextIdempotencyKey = null,
  switching = false,
} = {}) {
  const source = draft || {};
  const toId = toIdentity && toIdentity.id ? String(toIdentity.id) : null;
  const changing = Boolean(toId) && toId !== fromIdentityId;
  const registered = Boolean(toIdentity) && toIdentity.registered !== false && Boolean(toId);
  const authorized = Boolean(toIdentity) && toIdentity.authorization === 'ready';
  const supported = Boolean(toIdentity)
    && ENABLED_SENDER_KINDS.includes(toIdentity.kind)
    && ENABLED_SENDER_PROVIDERS.includes(toIdentity.provider);
  const sessionTarget = Boolean(toId) && toId === sessionIdentityId;
  const media = Array.isArray(source.media) ? source.media : [];
  const keptMedia = changing
    ? media.filter(item => {
      const owner = mediaOwner(item, fromIdentityId);

      return owner === toId && owner !== fromIdentityId;
    })
    : media;
  const keptIds = keptMedia.map(item => item.id);
  const reasons = [];

  if (!registered) {
    reasons.push('unregistered');
  }

  if (toIdentity && !authorized) {
    reasons.push('unauthorized');
  }

  if (toIdentity && !supported) {
    reasons.push('unsupported');
  }

  if (switching || source.senderStatus === 'switching') {
    reasons.push('switching');
  }

  if (source.senderStatus === 'unresolved' || source.senderStatus === 'failed' || source.senderStatus === 'unavailable') {
    reasons.push(source.senderStatus);
  }

  if (changing && source.mediaUploading) {
    reasons.push('media_uploading');
  }

  if (changing && source.editingId) {
    reasons.push('edit_bound');
  }

  if (toId && sessionIdentityId && toId !== sessionIdentityId) {
    reasons.push('not_enabled');
  }

  const style = applyPostingStylePrecedence({
    identity: toIdentity,
    postingContext: source.postingContext,
    userPostingContext: source.userPostingContext,
    manual: source.manual,
  });
  const refreshGroupDiscovery = changing && Boolean(source.groupId);
  const mustRevalidateReply = changing && Boolean(source.replyToId);
  const mustRevalidateQuote = changing && Boolean(source.quoteId);
  const permitted = reasons.length === 0 && authorized && supported && sessionTarget;

  return {
    permitted,
    reason: reasons[0] || (changing ? 'ready' : 'unchanged'),
    changing,
    fromIdentityId,
    toIdentityId: toId,
    preserveText: true,
    preservedText: source.text || '',
    preservePostingStyle: true,
    style,
    keptMediaIds: keptIds,
    rejectedMediaIds: media.map(item => item.id).filter(id => !keptIds.includes(id)),
    discardMedia: changing && keptIds.length !== media.length,
    rotateIdempotencyKey: changing,
    nextIdempotencyKey: changing ? nextIdempotencyKey : (source.idempotencyKey || null),
    discardViewerEvidence: changing,
    reuseViewerEvidence: !changing,
    reuseFollows: !changing,
    reuseAffiliations: !changing,
    nextViewerIdentityId: changing ? toId : fromIdentityId,
    refreshGroupDiscovery,
    mustRevalidateReply,
    mustRevalidateQuote,
    canSend: permitted && !changing && source.senderStatus === 'ready' && style.canPost,
  };
}

export function composerSenderSwitchDraft(composer, viewerEvidence) {
  if (!composer) {
    return {};
  }

  const surface = composer.get('surface');
  const groupId = surface && surface.get('kind') === 'group' ? surface.get('key') : null;
  const fromIdentityId = composer.getIn(['senderIdentity', 'id']);

  return {
    text: composer.get('text') || '',
    media: composer.get('media_attachments').map(item => ({
      id: item.get('id'),
      ownerIdentityId: item.get('ownerIdentityId') || fromIdentityId,
    })).toArray(),
    mediaUploading: composer.get('is_uploading') === true || composer.get('pending_media_attachments') > 0,
    poll: composer.get('poll'),
    replyToId: composer.get('in_reply_to'),
    quoteId: composer.get('quote_from'),
    editingId: composer.get('id'),
    scheduled: composer.get('scheduled') || composer.get('scheduled_status_id'),
    groupId,
    postingContext: {
      key: composer.getIn(['context', 'key']),
      locks: {},
      viewerEvidence: viewerEvidence || null,
    },
    userPostingContext: {
      id: composer.getIn(['userPostingStyle', 'selectedId']),
      privacy: composer.get('privacy'),
    },
    manual: {},
    idempotencyKey: composer.get('idempotencyKey'),
    senderStatus: composer.getIn(['senderIdentity', 'status']),
  };
}
