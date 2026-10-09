import { Map as ImmutableMap } from 'immutable';
import { me } from '../initial_state';

export const LOCAL_POSTING_IDENTITY_KIND = 'local';
export const LOCAL_POSTING_IDENTITY_PROVIDER = 'fedibird';
export const KNOWN_SENDER_KINDS = ['local', 'delegated', 'mastodon', 'misskey', 'bluesky'];
export const DELEGATED_POSTING_IDENTITY_KIND = 'delegated';
export const ENABLED_SENDER_KINDS = [LOCAL_POSTING_IDENTITY_KIND, DELEGATED_POSTING_IDENTITY_KIND];
export const ENABLED_SENDER_PROVIDERS = [LOCAL_POSTING_IDENTITY_PROVIDER];
export const POSTING_CAPABILITIES = ['post', 'media', 'reply', 'group', 'schedule'];

export const localPostingIdentityId = accountId => {
  if (accountId === null || accountId === undefined || accountId === '') {
    return null;
  }

  return `local:${accountId}`;
};

export const sessionPostingIdentityId = () => localPostingIdentityId(me);

export const initialSenderIdentity = () => ImmutableMap({
  id: sessionPostingIdentityId(),
  selectionOrigin: 'default',
  status: 'ready',
  changeEpoch: 0,
});

export const normalizePostingIdentity = data => {
  const source = data || {};
  const account = source.account || {};
  const capabilities = source.capabilities || {};
  const normalizedCapabilities = {};

  POSTING_CAPABILITIES.forEach(key => {
    normalizedCapabilities[key] = capabilities[key] === 'supported' ? 'supported' : 'unavailable';
  });

  return {
    id: source.id ? String(source.id) : null,
    kind: source.kind || null,
    provider: source.provider || null,
    authorization: source.authorization === 'ready' ? 'ready' : 'unavailable',
    account: {
      id: account.id === null || account.id === undefined || account.id === '' ? null : String(account.id),
      acct: account.acct || '',
      displayName: account.display_name || account.displayName || '',
      avatar: account.avatar || '',
      avatarStatic: account.avatar_static || account.avatarStatic || '',
    },
    capabilities: normalizedCapabilities,
  };
};
