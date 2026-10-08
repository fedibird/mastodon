import { POSTING_CONTEXT_CACHE_TTL } from '../actions/posting_contexts';
import { selectComposer } from '../selectors/composer';
import { selectPostingContextRevalidation } from '../selectors/posting_context_revalidations';
import { selectPostingContextDiscovery } from '../selectors/posting_contexts';
import { selectComposerPostingContextCompliance } from './compliance';
import { normalizeManagedHashtagName } from './managed_hashtags';

// Delivery support is keyed by the discovery adapter id.
// Authority is copied from discovery and is never rewritten from permission
// evidence or from a software name. Register a future protocol adapter here.
const SUPPORTED_DELIVERY_ADAPTERS = {
  fedibird_group: true,
  mitra_group: true,
};

const present = value => value !== null && value !== undefined && value !== '';

const emptyVisibility = () => ({
  valid: true,
  allowed: null,
  available: null,
});

const notApplicablePermission = (freshness = 'not_applicable') => ({
  status: 'not_applicable',
  source: null,
  viaRelationship: null,
  confirmed: false,
  freshness,
});

const delegatedDelivery = () => ({
  status: 'not_applicable',
  authority: null,
  adapter: null,
});

const permissionEvidenceFreshness = (record, now) => {
  if (!record || !record.get) {
    return 'absent';
  }

  if (record.get('refreshing') === true) {
    return 'refreshing';
  }

  if (record.get('refreshError')) {
    return 'refresh_failed';
  }

  const receivedAt = record.get('receivedAt');

  if (typeof receivedAt !== 'number') {
    return 'absent';
  }

  if ((now - receivedAt) >= POSTING_CONTEXT_CACHE_TTL) {
    return 'stale';
  }

  return 'current';
};

const knownPermissionStatus = status => (
  status === 'allowed' || status === 'unknown' || status === 'not_applicable'
);

const resolveDelivery = record => {
  if (!record || !record.get) {
    return {
      status: 'unresolved',
      authority: null,
      adapter: null,
    };
  }

  const status = record.get('status');
  const adapter = record.getIn(['discovery', 'adapter']) || null;
  const authority = record.getIn(['discovery', 'authority']) || null;

  if (!status || status === 'loading' || status === 'error') {
    return {
      status: 'unresolved',
      authority,
      adapter,
    };
  }

  if (status === 'not_applicable') {
    return delegatedDelivery();
  }

  if (status === 'unsupported') {
    return {
      status: 'unsupported',
      authority: null,
      adapter: null,
    };
  }

  if (status === 'resolved' && adapter && SUPPORTED_DELIVERY_ADAPTERS[adapter]) {
    return {
      status: 'supported',
      authority,
      adapter,
    };
  }

  return {
    status: 'unsupported',
    authority,
    adapter,
  };
};

const resolvePermission = (record, delivery, now) => {
  // A local server-authoritative group keeps its own posting rules.
  // Missing FEP evidence must not become protocol allowed.
  if (delivery.adapter === 'fedibird_group' && delivery.authority === 'server') {
    return notApplicablePermission();
  }

  if (delivery.status === 'not_applicable') {
    return notApplicablePermission();
  }

  const freshness = permissionEvidenceFreshness(record, now);
  const create = record && record.getIn ? record.getIn(['viewerEvidence', 'permissions', 'create']) : null;
  const rawStatus = create && create.get ? create.get('status') : null;
  const status = knownPermissionStatus(rawStatus) ? rawStatus : 'unknown';

  return {
    status,
    source: create && create.get ? (create.get('source') || null) : null,
    viaRelationship: create && create.get ? (create.get('viaRelationship') || null) : null,
    confirmed: status === 'allowed' && freshness === 'current',
    freshness,
  };
};

const result = ({ permission, delivery, compliance, canAttempt, reason }) => ({
  permission,
  delivery,
  compliance: {
    valid: compliance.valid,
    visibility: compliance.visibility || emptyVisibility(),
    followingAccounts: compliance.followingAccounts || [],
  },
  canAttempt,
  reason: canAttempt ? null : reason,
});

const delegatedResult = compliance => result({
  permission: notApplicablePermission(),
  delivery: delegatedDelivery(),
  compliance,
  canAttempt: compliance.valid,
  reason: compliance.valid ? null : 'compliance',
});

const valueAt = (record, key) => {
  if (!record) {
    return null;
  }

  const value = typeof record.get === 'function' ? record.get(key) : record[key];

  return value === undefined ? null : value;
};

const asList = value => {
  if (!value) {
    return [];
  }

  if (typeof value.toArray === 'function') {
    return value.toArray();
  }

  return Array.isArray(value) ? value : [];
};

const textOrNull = value => (
  value === null || value === undefined || value === '' ? null : String(value)
);

const acctOf = record => {
  const acct = textOrNull(valueAt(record, 'acct'));

  return acct ? acct.replace(/^@+/u, '') : null;
};

const ruleRecord = record => {
  if (!record) {
    return null;
  }

  return {
    accountId: textOrNull(valueAt(record, 'accountId')),
    acct: acctOf(record),
    enforcement: textOrNull(valueAt(record, 'enforcement')),
    ruleId: textOrNull(valueAt(record, 'ruleId')),
  };
};

const hashtagRecord = record => ({
  name: String(valueAt(record, 'name') || '').replace(/^[#＃]+/u, ''),
  normalizedName: normalizeManagedHashtagName(valueAt(record, 'normalizedName') || valueAt(record, 'name') || ''),
  enforcement: textOrNull(valueAt(record, 'enforcement')),
  ruleId: textOrNull(valueAt(record, 'ruleId')),
});

const sortedSignatures = items => items.map(item => JSON.stringify(item)).sort();

const visibilitySignature = value => {
  if (!value) {
    return null;
  }

  return asList(value).map(item => String(item)).sort();
};

// Server-defined descriptor. Composer suppressions and other user state are omitted.
// The key is compared as a whole and is never parsed for an account id.
const contextDescriptor = context => {
  const key = textOrNull(valueAt(context, 'key'));

  if (!key) {
    return null;
  }

  const source = valueAt(context, 'source');
  const managed = valueAt(context, 'managed');
  const requirements = valueAt(context, 'requirements');
  const constraints = valueAt(context, 'constraints');
  const protocol = valueAt(context, 'protocol');
  const activityPub = valueAt(protocol, 'activityPub');
  const revision = source ? valueAt(source, 'revision') : null;

  return {
    key,
    sourceId: source ? textOrNull(valueAt(source, 'id')) : null,
    sourceRevision: revision === undefined ? null : revision,
    hashtags: sortedSignatures(asList(valueAt(managed, 'hashtags')).map(hashtagRecord)),
    mentions: sortedSignatures(asList(valueAt(managed, 'mentions')).map(ruleRecord)),
    followingAccounts: sortedSignatures(asList(valueAt(requirements, 'followingAccounts')).map(ruleRecord)),
    allowedVisibilities: visibilitySignature(valueAt(constraints, 'allowedVisibilities')),
    audience: ruleRecord(valueAt(activityPub, 'audience')),
  };
};

const appliedContextMatchesDiscovery = (composer, discovery, targetAccountId) => {
  const applied = composer.get('context');
  const resolvedAccountId = applied && applied.get('resolvedAccountId');
  const appliedDescriptor = contextDescriptor(applied);
  const discoveryContext = discovery && typeof discovery.get === 'function' ? discovery.get('context') : null;
  const discoveryDescriptor = contextDescriptor(discoveryContext);

  if (!present(resolvedAccountId) || String(resolvedAccountId) !== String(targetAccountId)) {
    return false;
  }

  if (!appliedDescriptor || !discoveryDescriptor) {
    return false;
  }

  return JSON.stringify(appliedDescriptor) === JSON.stringify(discoveryDescriptor);
};

const groupAttempt = ({ permission, delivery, compliance, aligned }) => {
  if (delivery.status === 'unsupported') {
    return result({
      permission,
      delivery,
      compliance,
      canAttempt: false,
      reason: 'delivery_unsupported',
    });
  }

  if (delivery.status === 'unresolved') {
    return result({
      permission,
      delivery,
      compliance,
      canAttempt: false,
      reason: 'delivery_unresolved',
    });
  }

  // An explicit group target needs the current supported context.
  // not_applicable discovery is not a normal-post fallback.
  if (delivery.status !== 'supported' || !aligned) {
    return result({
      permission,
      delivery,
      compliance,
      canAttempt: false,
      reason: 'target_mismatch',
    });
  }

  return result({
    permission,
    delivery,
    compliance,
    canAttempt: compliance.valid,
    reason: compliance.valid ? null : 'compliance',
  });
};

// Effective create capability for one composer.
//
// permission, delivery, and compliance stay independent.
// canAttempt means the known conditions allow a send attempt.
// It does not mean a remote group will accept the post.
export function selectComposerEffectiveCreateCapability(state, composerId, now = Date.now()) {
  const composer = selectComposer(state, composerId);
  const compliance = selectComposerPostingContextCompliance(state, composerId);

  if (!composer) {
    return result({
      permission: notApplicablePermission(),
      delivery: delegatedDelivery(),
      compliance: {
        valid: false,
        visibility: emptyVisibility(),
        followingAccounts: [],
      },
      canAttempt: false,
      reason: null,
    });
  }

  // Existing status edits and scheduled edits keep their current rules.
  // A scheduled draft still obeys its saved audience visibility constraint.
  const targetAccountId = composer.get('posting_context_account_id');

  if (present(composer.get('id')) || present(composer.get('scheduled_status_id')) || !present(targetAccountId)) {
    return delegatedResult(compliance);
  }

  const discovery = selectPostingContextDiscovery(state, targetAccountId);
  const delivery = resolveDelivery(discovery);
  const permission = applyRevalidationOverlay(resolvePermission(discovery, delivery, now), state, targetAccountId);

  return groupAttempt({
    permission,
    delivery,
    compliance,
    aligned: appliedContextMatchesDiscovery(composer, discovery, targetAccountId),
  });
}

const REVALIDATION_BLOCKS_CONFIRMATION = {
  queued: true,
  running: true,
  failed: true,
  partial: true,
};

// A revalidation job is not permission evidence. While it is unfinished or
// did not fully succeed, leftover positive evidence is not "latest confirmed".
const applyRevalidationOverlay = (permission, state, targetAccountId) => {
  if (!permission || permission.status === 'not_applicable') {
    return permission;
  }

  const revalidation = selectPostingContextRevalidation(state, targetAccountId);
  const jobState = revalidation && revalidation.get ? revalidation.get('state') : null;

  if (!REVALIDATION_BLOCKS_CONFIRMATION[jobState]) {
    return permission;
  }

  return {
    ...permission,
    confirmed: false,
  };
};

const WARNING_NOTICES = {
  allowed_unsupported: true,
  unsupported: true,
  unresolved: true,
  mismatch: true,
};

export function createCapabilityNotice(capability) {
  if (!capability) {
    return null;
  }

  const { permission, delivery, reason } = capability;

  if (reason === 'target_mismatch') {
    return 'mismatch';
  }

  if (delivery.status === 'unsupported' || reason === 'delivery_unsupported') {
    if (permission.confirmed && permission.status === 'allowed') {
      return 'allowed_unsupported';
    }

    return 'unsupported';
  }

  if (delivery.status === 'unresolved' || reason === 'delivery_unresolved') {
    return 'unresolved';
  }

  if (delivery.adapter === 'fedibird_group' && delivery.authority === 'server') {
    return null;
  }

  if (permission.freshness === 'refreshing') {
    return 'refreshing';
  }

  if (permission.freshness === 'refresh_failed') {
    return 'refresh_failed';
  }

  if (permission.status === 'not_applicable' || delivery.status === 'not_applicable') {
    return null;
  }

  if (permission.confirmed && delivery.status === 'supported' && delivery.authority === 'compatibility') {
    return 'allowed_compatibility';
  }

  if (permission.confirmed && delivery.status === 'supported' && delivery.authority === 'protocol') {
    return 'allowed';
  }

  if (delivery.status === 'supported' && delivery.authority === 'compatibility' && !permission.confirmed) {
    return 'unknown_compatibility';
  }

  return null;
}

export function createCapabilityNoticeIsWarning(notice) {
  return Boolean(WARNING_NOTICES[notice]);
}
