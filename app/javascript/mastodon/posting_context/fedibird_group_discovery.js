import { FEDIBIRD_GROUP_KEY } from '../posting_identity/group_destination';

const present = value => value !== null && value !== undefined && value !== '';

const readAccountId = record => {
  if (!record || !record.get) {
    return null;
  }

  const accountId = record.get('accountId');

  return present(accountId) ? String(accountId) : null;
};

const requiredRulesForAccount = (rules, accountId, { requireRules = false } = {}) => {
  if (!rules || !rules.filter) {
    return !requireRules;
  }

  const required = rules.filter(rule => rule && rule.get && rule.get('enforcement') === 'required');

  if (!required.size) {
    return !requireRules;
  }

  return required.every(rule => readAccountId(rule) === accountId);
};

export function isLocalFedibirdGroupAccount (account) {
  if (!account || !account.get) {
    return false;
  }

  if (account.get('group') !== true) {
    return false;
  }

  const acct = String(account.get('acct') || '');

  return acct.length > 0 && !acct.includes('@');
}

export function isResolvedFedibirdGroupDiscovery (discoveryRecord, accountId) {
  if (!discoveryRecord || !discoveryRecord.get || !present(accountId)) {
    return false;
  }

  const id = String(accountId);

  if (discoveryRecord.get('status') !== 'resolved') {
    return false;
  }

  if (discoveryRecord.getIn(['discovery', 'adapter']) !== 'fedibird_group') {
    return false;
  }

  if (discoveryRecord.getIn(['discovery', 'authority']) !== 'server') {
    return false;
  }

  const context = discoveryRecord.get('context');

  if (!context || !context.get) {
    return false;
  }

  const match = String(context.get('key') || '').match(FEDIBIRD_GROUP_KEY);

  if (!match || match[1] !== id) {
    return false;
  }

  if (!requiredRulesForAccount(context.getIn(['managed', 'mentions']), id, { requireRules: true })) {
    return false;
  }

  return requiredRulesForAccount(context.getIn(['requirements', 'followingAccounts']), id);
}

export function isPublicFedibirdGroupTimeline (discoveryRecord, account) {
  if (!isLocalFedibirdGroupAccount(account)) {
    return false;
  }

  const accountId = account.get('id');

  return isResolvedFedibirdGroupDiscovery(discoveryRecord, accountId);
}
