const serial = new Map();

// One composer has one current group-discovery generation. A later
// fetch, sender change, or group change advances it so an older
// response cannot authorize the composer that is on screen now.
export function beginComposerDiscovery (composerId) {
  const next = (serial.get(composerId) || 0) + 1;

  serial.set(composerId, next);

  return next;
}

export function composerDiscoveryIsCurrent (composerId, generation) {
  return serial.get(composerId) === generation;
}

export function captureGroupDiscovery (composer, composerId, accountId, delegationId, selectedId) {
  return {
    composerId,
    identityId: (composer && composer.getIn(['senderIdentity', 'id'])) || null,
    delegationId: delegationId || null,
    changeEpoch: Number(composer && composer.getIn(['senderIdentity', 'changeEpoch'])) || 0,
    accountId: String(accountId),
    selectedId: selectedId || null,
    generation: beginComposerDiscovery(composerId),
  };
}

// The group rules may be shared. This check is the sender, the grant
// generation, and the group the request was started for.
export function groupDiscoveryMatches (composer, snapshot, delegationId) {
  if (!composer || !snapshot || !composerDiscoveryIsCurrent(snapshot.composerId, snapshot.generation)) {
    return false;
  }

  const identityId = composer.getIn(['senderIdentity', 'id']) || null;
  const epoch = Number(composer.getIn(['senderIdentity', 'changeEpoch'])) || 0;
  const destinationId = composer.getIn(['userPostingStyle', 'destinationAccountId']);
  const appliedId = composer.get('posting_context_account_id');
  const selectedId = composer.getIn(['userPostingStyle', 'selectedId']) || null;

  if (snapshot.selectedId && selectedId !== snapshot.selectedId) {
    return false;
  }

  if (destinationId && String(destinationId) !== snapshot.accountId) {
    return false;
  }

  if (!destinationId && appliedId && String(appliedId) !== snapshot.accountId) {
    return false;
  }

  if (!destinationId && !appliedId) {
    return false;
  }

  return identityId === snapshot.identityId
    && String(delegationId || '') === String(snapshot.delegationId || '')
    && epoch === snapshot.changeEpoch;
}
