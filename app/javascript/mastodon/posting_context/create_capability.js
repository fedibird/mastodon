import { POSTING_CONTEXT_CACHE_TTL } from '../actions/posting_contexts';
import { selectComposer } from '../selectors/composer';
import { selectPostingContextDiscovery } from '../selectors/posting_contexts';
import { selectComposerPostingContextCompliance } from './compliance';

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

const groupAttempt = ({ permission, delivery, compliance, mismatch }) => {
  if (mismatch) {
    return result({
      permission,
      delivery,
      compliance,
      canAttempt: false,
      reason: 'target_mismatch',
    });
  }

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
  const permission = resolvePermission(discovery, delivery, now);
  const resolvedAccountId = composer.getIn(['context', 'resolvedAccountId']);
  const mismatch = present(resolvedAccountId) && String(resolvedAccountId) !== String(targetAccountId);

  return groupAttempt({
    permission,
    delivery,
    compliance,
    mismatch,
  });
}

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

  if (permission.confirmed && permission.status === 'allowed' && delivery.status === 'unsupported') {
    return 'allowed_unsupported';
  }

  if (delivery.status === 'supported' && delivery.authority === 'compatibility' && !permission.confirmed) {
    return 'unknown_compatibility';
  }

  if (delivery.status === 'unsupported') {
    return 'unsupported';
  }

  if (reason === 'target_mismatch') {
    return 'mismatch';
  }

  if (reason === 'delivery_unresolved') {
    return 'unresolved';
  }

  return null;
}

export function createCapabilityNoticeIsWarning(notice) {
  return Boolean(WARNING_NOTICES[notice]);
}
