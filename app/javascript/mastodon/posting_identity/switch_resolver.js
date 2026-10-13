import { consistentLocalFedibirdGroup, consistentSupportedRemoteGroup, draftHasGroupDestination } from './group_destination';
import { ENABLED_SENDER_KINDS, ENABLED_SENDER_PROVIDERS } from './identity';
import { applyPostingStylePrecedence } from './style_precedence';

const mediaOwner = (item, fromIdentityId) => (
  item && item.ownerIdentityId ? item.ownerIdentityId : fromIdentityId
);

const capabilitySupported = (identity, name) => {
  const capabilities = identity && identity.capabilities;

  if (!capabilities || !Object.prototype.hasOwnProperty.call(capabilities, name)) {
    return name === 'quote' && Boolean(identity) && identity.kind !== 'delegated';
  }

  return capabilities[name] === 'supported';
};

const presentId = value => value !== null && value !== undefined && value !== '';

// A style can name its group before discovery has written the context key.
// The switch is allowed only when every id that is already present agrees
// and the target has group. Send still waits for that discovery.
const pendingStyleGroup = source => {
  const status = source.styleDestinationStatus;

  if (status !== 'pending' && status !== 'needs_resolve') {
    return false;
  }

  if (source.activityPubAudience) {
    return false;
  }

  if (source.contextKey && !consistentLocalFedibirdGroup(source)) {
    return false;
  }

  const id = source.styleDestinationAccountId || source.postingContextAccountId;

  if (!presentId(id)) {
    return false;
  }

  return [id, source.postingContextAccountId, source.resolvedAccountId, source.groupId]
    .filter(presentId)
    .every(item => String(item) === String(id));
};

// Lemmy, PieFed, and group replies stay refused. A consistent local
// Fedibird group, a supported remote group, or a style still resolving
// one, can move to an identity that was granted group together with post.
const groupSwitchBlocked = (source, toIdentity) => {
  if (!draftHasGroupDestination(source)) {
    return false;
  }

  if (source.replyToId || source.quoteId) {
    return true;
  }

  if (!capabilitySupported(toIdentity, 'group')) {
    return true;
  }

  return !(consistentLocalFedibirdGroup(source) || consistentSupportedRemoteGroup(source) || pendingStyleGroup(source));
};

// Pure description of a future sender change. M1 never permits the change
// itself. effectsApplied stays false: discarding media, refreshing group
// discovery, and rotating the idempotency key are instructions, not work
// this resolver or the composer reducer has carried out.
export function resolveSenderIdentitySwitch({
  fromIdentityId = null,
  toIdentity = null,
  draft = {},
  sessionIdentityId = null,
  nextIdempotencyKey = null,
  switching = false,
  confirmed = false,
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
  const postSupported = Boolean(toIdentity) && toIdentity.capabilities && toIdentity.capabilities.post === 'supported';
  const delegatedTarget = Boolean(toIdentity) && toIdentity.kind === 'delegated' && postSupported;
  const localSessionTarget = Boolean(toIdentity) && toIdentity.kind === 'local' && sessionTarget;
  const targetAllowed = !changing || delegatedTarget || localSessionTarget;
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

  if (changing && media.some(item => mediaOwner(item, fromIdentityId) !== toId)) {
    reasons.push('media');
  }

  if (changing && source.poll) {
    reasons.push('poll');
  }

  if (changing && source.editingId) {
    reasons.push('edit_bound');
  }

  if (changing && source.scheduled) {
    reasons.push('schedule_bound');
  }

  if (changing && source.replyToId && !capabilitySupported(toIdentity, 'reply')) {
    reasons.push('reply');
  }

  if (changing && source.quoteId && !capabilitySupported(toIdentity, 'quote')) {
    reasons.push('quote');
  }

  if (changing && groupSwitchBlocked(source, toIdentity)) {
    reasons.push('group');
  }

  if (changing && source.submitting) {
    reasons.push('submitting');
  }

  if (changing && !targetAllowed) {
    reasons.push('not_enabled');
  }

  const textPresent = typeof source.text === 'string' && source.text.trim() !== '';
  const confirmSender = changing && targetAllowed && reasons.length === 0 && textPresent && confirmed !== true;

  if (confirmSender) {
    reasons.push('confirm_sender');
  }

  const rotatedKey = nextIdempotencyKey && nextIdempotencyKey !== source.idempotencyKey
    ? nextIdempotencyKey
    : null;

  if (changing && targetAllowed && reasons.length === 0 && !rotatedKey) {
    reasons.push('idempotency');
  }

  const style = applyPostingStylePrecedence({
    identity: toIdentity,
    postingContext: source.postingContext,
    userPostingContext: source.userPostingContext,
    manual: source.manual,
  });
  const refreshGroupDiscovery = changing && draftHasGroupDestination(source);
  const mustRevalidateReply = changing && Boolean(source.replyToId);
  const mustRevalidateQuote = changing && Boolean(source.quoteId);
  const mustRevalidateGroup = changing
    && capabilitySupported(toIdentity, 'group')
    && !source.replyToId
    && !source.quoteId
    && (consistentLocalFedibirdGroup(source) || consistentSupportedRemoteGroup(source) || pendingStyleGroup(source));
  const permitted = reasons.length === 0 && authorized && supported && (changing ? targetAllowed : sessionTarget);

  return {
    permitted,
    effectsApplied: permitted && changing,
    requiresConfirmation: confirmSender,
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
    nextIdempotencyKey: changing ? rotatedKey : (source.idempotencyKey || null),
    editBound: changing && Boolean(source.editingId),
    scheduleBound: changing && Boolean(source.scheduled),
    discardViewerEvidence: changing,
    reuseViewerEvidence: !changing,
    reuseFollows: !changing,
    reuseAffiliations: !changing,
    nextViewerIdentityId: changing ? toId : fromIdentityId,
    refreshGroupDiscovery,
    mustRevalidateReply,
    mustRevalidateQuote,
    mustRevalidateGroup,
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
    mediaUploading: composer.get('is_uploading') === true || composer.get('pending_media_attachments') > 0 || composer.get('is_processing') === true || composer.get('is_changing_upload') === true || (composer.get('uploadRequests') && composer.get('uploadRequests').size > 0),
    poll: composer.get('poll'),
    replyToId: composer.get('in_reply_to'),
    quoteId: composer.get('quote_from'),
    editingId: composer.get('id'),
    scheduled: composer.get('scheduled') || composer.get('scheduled_status_id'),
    groupId,
    styleDestinationStatus: composer.getIn(['userPostingStyle', 'destinationStatus']),
    styleDestinationAccountId: composer.getIn(['userPostingStyle', 'destinationAccountId']),
    postingContextAccountId: composer.get('posting_context_account_id'),
    resolvedAccountId: composer.getIn(['context', 'resolvedAccountId']),
    contextKey: composer.getIn(['context', 'key']),
    contextRevision: composer.getIn(['context', 'source', 'revision']),
    activityPubAudience: composer.getIn(['context', 'protocol', 'activityPub', 'audience']),
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
    submitting: composer.get('is_submitting') === true,
  };
}
