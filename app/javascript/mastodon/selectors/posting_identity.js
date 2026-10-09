import { me } from '../initial_state';
import { senderMaySubmit, senderMayUpload } from '../posting_identity/identity';
import { selectComposer } from './composer';

const plainIdentity = identity => {
  if (!identity || !identity.get) {
    return null;
  }

  const capabilities = identity.get('capabilities');

  return {
    id: identity.get('id'),
    authorization: identity.get('authorization'),
    accountId: identity.getIn(['account', 'id']),
    capabilities: capabilities && capabilities.toJS ? capabilities.toJS() : capabilities,
  };
};

const senderOptions = (state, composerId) => {
  const composer = selectComposer(state, composerId);
  const sender = composer && composer.get('senderIdentity');
  const catalogStatus = state.getIn(['postingIdentities', 'status'], 'idle');
  const identities = state.getIn(['postingIdentities', 'identities']);
  const senderId = sender && sender.get('id');
  const identity = identities && identities.find ? identities.find(item => item.get('id') === senderId) : null;

  return {
    sender: sender && sender.toJS ? sender.toJS() : null,
    identity: plainIdentity(identity),
    authenticatedAccountId: me,
    catalogStatus,
  };
};

export const selectComposerSenderIdentity = (state, composerId) => {
  const composer = selectComposer(state, composerId);

  if (!composer || !composer.get) {
    return null;
  }

  return composer.get('senderIdentity') || null;
};

export const selectComposerCanSendAsIdentity = (state, composerId) => (
  senderMaySubmit(senderOptions(state, composerId))
);

export const selectComposerCanUploadAsIdentity = (state, composerId) => (
  senderMayUpload(senderOptions(state, composerId))
);
