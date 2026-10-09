import { Map as ImmutableMap } from 'immutable';

export const localPostingIdentityId = accountId => {
  if (accountId === null || accountId === undefined || accountId === '') {
    return null;
  }

  return `local:${accountId}`;
};

export const initialSenderIdentity = (accountId = null) => ImmutableMap({
  id: localPostingIdentityId(accountId),
  selectionOrigin: 'default',
  status: 'ready',
  changeEpoch: 0,
});

const capabilitySupported = (identity, name) => (
  Boolean(identity && identity.capabilities && identity.capabilities[name] === 'supported')
);

const sameAccount = (left, right) => (
  left !== null && left !== undefined && right !== null && right !== undefined && String(left) === String(right)
);

// A composer that predates this field still posts as the signed-in session.
// Once a sender is present, a failed catalog, a foreign id, or anything
// other than a ready grant for the authenticated account cannot submit.
export const senderMaySubmit = ({
  sender,
  identity,
  authenticatedAccountId,
  catalogStatus,
}) => {
  if (!sender) {
    return true;
  }

  if (sender.status !== 'ready') {
    return false;
  }

  if (catalogStatus === 'failed' || catalogStatus === 'unauthorized') {
    return false;
  }

  const sessionId = localPostingIdentityId(authenticatedAccountId);

  if (sender.id && sessionId && sender.id !== sessionId) {
    return false;
  }

  if (catalogStatus !== 'ready') {
    return true;
  }

  if (!identity || identity.authorization !== 'ready' || !capabilitySupported(identity, 'post')) {
    return false;
  }

  if (sessionId && identity.id !== sessionId) {
    return false;
  }

  const accountId = identity.accountId || (identity.account && identity.account.id);

  if (authenticatedAccountId && !sameAccount(accountId, authenticatedAccountId)) {
    return false;
  }

  return true;
};

export const senderMayUpload = (options) => {
  if (!senderMaySubmit(options)) {
    return false;
  }

  if (options.catalogStatus !== 'ready') {
    return true;
  }

  return capabilitySupported(options.identity, 'media');
};
