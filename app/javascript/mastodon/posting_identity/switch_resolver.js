import { localPostingIdentityId } from './identity';

const list = value => (Array.isArray(value) ? value : []);

const capabilitySupported = (identity, name) => (
  Boolean(identity && identity.capabilities && identity.capabilities[name] === 'supported')
);

// Describes a future sender change without performing it.
// M1 permits no identity except the authenticated local account, and a
// change to that same account is not a switch. The effects still state
// the boundary a later switch has to keep: text and posting style stay,
// media ids and group-viewer evidence do not.
export function resolveSenderIdentitySwitch(current, next, options = {}) {
  const source = current || {};
  const currentId = source.identityId || null;
  const nextId = next && next.id ? next.id : null;
  const changed = currentId !== nextId;
  const sessionId = localPostingIdentityId(source.authenticatedAccountId);
  const mediaIds = list(source.mediaIds);
  const blockers = [];

  if (!next || !nextId) {
    blockers.push('unresolved');
  }

  if (next && next.authorization !== 'ready') {
    blockers.push('unauthorized');
  }

  if (next && !capabilitySupported(next, 'post')) {
    blockers.push('unsupported');
  }

  if (source.status === 'switching') {
    blockers.push('switching');
  }

  if (source.status === 'unresolved') {
    blockers.push('unresolved');
  }

  if (source.mediaUploading) {
    blockers.push('media_uploading');
  }

  if (changed && source.editingStatusId) {
    blockers.push('edit_bound_to_sender');
  }

  if (changed && source.scheduledStatusId) {
    blockers.push('schedule_bound_to_sender');
  }

  const sessionLocal = Boolean(
    next &&
    next.kind === 'local' &&
    sessionId &&
    nextId === sessionId &&
    String(next.accountId) === String(source.authenticatedAccountId),
  );

  if (changed && !sessionLocal) {
    blockers.push('not_enabled');
  }

  const nextKey = changed ? (options.nextIdempotencyKey || null) : (source.idempotencyKey || null);
  const idempotencyKey = changed && nextKey === source.idempotencyKey ? null : nextKey;
  const groupBound = Boolean(source.groupDestination || source.postingContextAccountId);

  return {
    changed,
    permittedNow: changed && blockers.length === 0,
    canSend: !changed && source.status === 'ready' && !source.mediaUploading && (
      !next || nextId !== currentId || (next.authorization === 'ready' && capabilitySupported(next, 'post'))
    ),
    blockers,
    effects: {
      preserve: {
        text: source.text,
        postingStyle: source.postingStyle,
        postingContext: source.postingContext,
        poll: source.poll,
      },
      reevaluateAuthorization: changed,
      media: {
        ownedByIdentityId: currentId,
        keepIds: changed ? [] : mediaIds.slice(),
        discardIds: changed ? mediaIds.slice() : [],
        blockWhileUploading: Boolean(source.mediaUploading),
      },
      reply: {
        statusId: source.replyTo || null,
        mustRevalidate: changed && Boolean(source.replyTo),
      },
      quote: {
        statusId: source.quoteFrom || null,
        mustRevalidate: changed && Boolean(source.quoteFrom),
      },
      edit: {
        statusId: source.editingStatusId || null,
        transferable: !changed,
      },
      schedule: {
        statusId: source.scheduledStatusId || null,
        transferable: !changed,
      },
      group: {
        refreshDiscovery: changed && groupBound,
        previousViewerAccountId: source.viewerAccountId || null,
        nextViewerAccountId: changed ? ((next && next.accountId) || null) : (source.viewerAccountId || null),
        reusePreviousViewerEvidence: !changed,
      },
      postingContext: {
        preserved: true,
        viewerEvidenceStale: changed && groupBound,
      },
      idempotencyKeyRotated: changed,
      idempotencyKey,
    },
  };
}
