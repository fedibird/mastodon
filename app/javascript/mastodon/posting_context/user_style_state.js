import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet } from 'immutable';
import uuid from '../uuid';
import { normalizeManagedHashtagName } from './managed_hashtags';
import { isExistingPostEdit, postingContextOutputSignature } from './materialize';
import { resolveUserPostingStyle } from './user_style_resolver';

const emptyProtocol = () => ImmutableMap({
  activityPub: ImmutableMap({
    audience: null,
  }),
});

export const emptyComposerPostingContext = () => ImmutableMap({
  key: null,
  source: null,
  managed: ImmutableMap({
    hashtags: ImmutableList(),
    mentions: ImmutableList(),
  }),
  suppressions: ImmutableMap({
    hashtags: ImmutableSet(),
  }),
  requirements: ImmutableMap({
    followingAccounts: ImmutableList(),
  }),
  constraints: ImmutableMap({
    allowedVisibilities: null,
  }),
  protocol: emptyProtocol(),
});

export const initialUserPostingStyle = () => ImmutableMap({
  selectedId: null,
  appliedRevision: null,
  status: 'idle',
  manualFields: ImmutableSet(),
  manualValues: ImmutableMap(),
  destinationSource: null,
  destinationStatus: 'idle',
  destinationAccountId: null,
  snapshot: null,
  styleOwnedFields: ImmutableSet(),
  unapplied: ImmutableList(),
  suppressions: ImmutableSet(),
  parkedContext: null,
  parkedDestinationStatus: null,
  parkedStyleId: null,
});

const searchabilityForPrivacy = (privacy, current) => {
  const order = ['public', 'unlisted', 'private', 'mutual', 'limited', 'direct', 'personal'];
  const to = ['public', 'private', 'private', 'direct', 'direct', 'direct', 'direct'];

  return to[Math.max(order.indexOf(privacy), order.indexOf(current), 0)];
};

const valueKey = field => {
  if (field === 'privacy') {
    return 'privacy';
  }

  if (field === 'language') {
    return 'language';
  }

  if (field === 'sensitive') {
    return 'sensitive';
  }

  return null;
};

export function rememberManualSetting(map, field) {
  if (!map.get('userPostingStyle')) {
    return;
  }

  map.updateIn(['userPostingStyle', 'manualFields'], set => (set || ImmutableSet()).add(field));

  if (field === 'spoiler') {
    map.setIn(['userPostingStyle', 'manualValues', 'spoiler'], map.get('spoiler'));
    map.setIn(['userPostingStyle', 'manualValues', 'spoilerText'], map.get('spoiler_text'));
    return;
  }

  const key = valueKey(field);

  if (key) {
    map.setIn(['userPostingStyle', 'manualValues', key], map.get(key));
  }
}

const clearParkedDestination = map => {
  map.setIn(['userPostingStyle', 'parkedContext'], null);
  map.setIn(['userPostingStyle', 'parkedDestinationStatus'], null);
  map.setIn(['userPostingStyle', 'parkedStyleId'], null);
};

const withoutDestination = list => (list || ImmutableList()).filter(item => item !== 'destination');

const withDestination = list => {
  const current = list || ImmutableList();

  return current.includes('destination') ? current : current.push('destination');
};

export function releaseStyleDestination(map) {
  if (map.getIn(['userPostingStyle', 'destinationSource']) !== 'style') {
    return;
  }

  if (map.getIn(['userPostingStyle', 'destinationStatus']) === 'skipped') {
    return;
  }

  map.setIn(['userPostingStyle', 'parkedContext'], map.get('context'));
  map.setIn(['userPostingStyle', 'parkedDestinationStatus'], map.getIn(['userPostingStyle', 'destinationStatus']));
  map.setIn(['userPostingStyle', 'parkedStyleId'], map.getIn(['userPostingStyle', 'selectedId']));
  map.set('context', emptyComposerPostingContext());
  map.setIn(['userPostingStyle', 'destinationStatus'], 'skipped');
  map.setIn(['userPostingStyle', 'unapplied'], withDestination(map.getIn(['userPostingStyle', 'unapplied'])));
}

export function abandonStyleDestination(map) {
  if (map.getIn(['userPostingStyle', 'destinationSource']) !== 'style') {
    return;
  }

  map.set('context', emptyComposerPostingContext());
  map.setIn(['userPostingStyle', 'destinationStatus'], 'skipped');
  clearParkedDestination(map);
  map.setIn(['userPostingStyle', 'unapplied'], withDestination(map.getIn(['userPostingStyle', 'unapplied'])));
}

const applyFields = (map, fields) => {
  if (Object.prototype.hasOwnProperty.call(fields, 'privacy')) {
    map.set('privacy', fields.privacy);
    map.set('searchability', searchabilityForPrivacy(fields.privacy, map.get('searchability')));
    map.set('circle_id', null);
  }

  if (Object.prototype.hasOwnProperty.call(fields, 'language')) {
    map.set('language', fields.language);
  }

  if (Object.prototype.hasOwnProperty.call(fields, 'spoiler')) {
    map.set('spoiler', fields.spoiler);
    map.set('spoiler_text', fields.spoiler ? (fields.spoilerText || '') : '');
  }

  if (Object.prototype.hasOwnProperty.call(fields, 'sensitive')) {
    map.set('sensitive', fields.sensitive);
  }
};

const restoreManualValues = map => {
  const fields = map.getIn(['userPostingStyle', 'manualFields'], ImmutableSet());
  const values = map.getIn(['userPostingStyle', 'manualValues'], ImmutableMap());

  if (fields.includes('privacy') && values.has('privacy')) {
    map.set('privacy', values.get('privacy'));
    map.set('searchability', searchabilityForPrivacy(values.get('privacy'), map.get('searchability')));
  }

  if (fields.includes('language') && values.has('language')) {
    map.set('language', values.get('language'));
  }

  if (fields.includes('spoiler') && values.has('spoiler')) {
    map.set('spoiler', values.get('spoiler'));
    map.set('spoiler_text', values.get('spoilerText') || '');
  }

  if (fields.includes('sensitive') && values.has('sensitive')) {
    map.set('sensitive', values.get('sensitive'));
  }
};

const clearStyleContext = map => {
  if (map.getIn(['userPostingStyle', 'destinationSource']) === 'style') {
    map.set('context', emptyComposerPostingContext());
  }
};

const applyClearStyle = map => {
  clearStyleContext(map);
  map.setIn(['userPostingStyle', 'destinationSource'], null);
  map.setIn(['userPostingStyle', 'destinationStatus'], 'idle');
  map.setIn(['userPostingStyle', 'destinationAccountId'], null);
  map.setIn(['userPostingStyle', 'status'], map.getIn(['userPostingStyle', 'selectedId']) ? 'applied' : 'idle');
  clearParkedDestination(map);
};

const applyHashtagDestination = map => {
  clearStyleContext(map);
  map.setIn(['userPostingStyle', 'destinationSource'], 'style');
  map.setIn(['userPostingStyle', 'destinationStatus'], 'ready');
  map.setIn(['userPostingStyle', 'destinationAccountId'], null);
  map.setIn(['userPostingStyle', 'status'], 'applied');
  clearParkedDestination(map);
};

const restoreParkedGroup = (map, previous, accountId) => {
  map.set('context', previous.getIn(['userPostingStyle', 'parkedContext']));
  const parkedStatus = previous.getIn(['userPostingStyle', 'parkedDestinationStatus']) || 'ready';
  map.setIn(['userPostingStyle', 'destinationSource'], 'style');
  map.setIn(['userPostingStyle', 'destinationAccountId'], accountId);
  map.setIn(['userPostingStyle', 'destinationStatus'], parkedStatus);
  map.setIn(['userPostingStyle', 'status'], parkedStatus === 'failed' ? 'failed' : 'applied');
  map.setIn(['userPostingStyle', 'unapplied'], parkedStatus === 'failed' ? withDestination(map.getIn(['userPostingStyle', 'unapplied'])) : withoutDestination(map.getIn(['userPostingStyle', 'unapplied'])));
  clearParkedDestination(map);
};

const applyGroupDestination = (map, previous, plan, restoreParked) => {
  const accountId = plan.destination.accountId === null || plan.destination.accountId === undefined ? null : String(plan.destination.accountId);
  const sameAccount = previous.getIn(['userPostingStyle', 'destinationSource']) === 'style' && String(previous.getIn(['userPostingStyle', 'destinationAccountId'] || '')) === String(accountId);
  const parked = previous.getIn(['userPostingStyle', 'parkedContext']);
  const replyOrQuote = previous.get('in_reply_to') || previous.get('quote_from');

  if (restoreParked && parked && previous.getIn(['userPostingStyle', 'parkedStyleId']) === plan.selectedId && !replyOrQuote) {
    restoreParkedGroup(map, previous, accountId);
    return;
  }

  if (sameAccount && previous.getIn(['userPostingStyle', 'destinationStatus']) === 'ready') {
    map.setIn(['userPostingStyle', 'status'], 'applied');
    map.setIn(['userPostingStyle', 'unapplied'], withoutDestination(map.getIn(['userPostingStyle', 'unapplied'])));
    return;
  }

  if (sameAccount && previous.getIn(['userPostingStyle', 'destinationStatus']) === 'failed') {
    map.set('context', emptyComposerPostingContext());
    map.setIn(['userPostingStyle', 'status'], 'failed');
    map.setIn(['userPostingStyle', 'unapplied'], withDestination(map.getIn(['userPostingStyle', 'unapplied'])));
    return;
  }

  if (sameAccount && (previous.getIn(['userPostingStyle', 'destinationStatus']) === 'pending' || previous.getIn(['userPostingStyle', 'destinationStatus']) === 'needs_resolve')) {
    return;
  }

  map.set('context', emptyComposerPostingContext());
  map.setIn(['userPostingStyle', 'destinationSource'], 'style');
  map.setIn(['userPostingStyle', 'destinationAccountId'], accountId);
  map.setIn(['userPostingStyle', 'destinationStatus'], restoreParked ? 'needs_resolve' : 'pending');
  map.setIn(['userPostingStyle', 'status'], 'applying');
  map.setIn(['userPostingStyle', 'unapplied'], withoutDestination(map.getIn(['userPostingStyle', 'unapplied'])));
  clearParkedDestination(map);
};

const applyDestination = (map, previous, plan, restoreParked) => {
  const action = plan.destination.action;

  if (action === 'keep') {
    return;
  }

  if (action === 'skip') {
    map.setIn(['userPostingStyle', 'destinationStatus'], 'skipped');
    map.setIn(['userPostingStyle', 'status'], 'applied');
    return;
  }

  if (action === 'clear_style') {
    applyClearStyle(map);
    return;
  }

  if (action === 'hashtag') {
    applyHashtagDestination(map);
    return;
  }

  if (action === 'group') {
    applyGroupDestination(map, previous, plan, restoreParked);
  }
};

// Values the status create request sends. Text and managed tags are included so
// a style apply rotates the key when any of them change, and leaves it when
// the request would be identical.
export function composerSubmissionSignature(composer) {
  if (!composer) {
    return '';
  }

  const spoiler = composer.get('spoiler') === true;

  return [
    composer.get('text') || '',
    composer.get('privacy') || '',
    composer.get('language') || '',
    spoiler ? '1' : '0',
    spoiler ? (composer.get('spoiler_text') || '') : '',
    composer.get('sensitive') === true ? '1' : '0',
    composer.get('searchability') || '',
    composer.get('circle_id') || '',
    postingContextOutputSignature(composer),
  ].join('\u001f');
}

const refreshIdempotency = (map, previous) => {
  if (composerSubmissionSignature(previous) === composerSubmissionSignature(map)) {
    return;
  }

  map.set('idempotencyKey', uuid());
};

export function commitUserPostingStyle(state, action) {
  if (isExistingPostEdit(state) || !action.plan || action.plan.blocked) {
    return state;
  }

  return state.withMutations(map => {
    applyFields(map, action.plan.fields || {});
    map.setIn(['userPostingStyle', 'selectedId'], action.plan.selectedId);
    map.setIn(['userPostingStyle', 'appliedRevision'], action.plan.revision);
    map.setIn(['userPostingStyle', 'snapshot'], action.snapshot || null);
    map.setIn(['userPostingStyle', 'styleOwnedFields'], ImmutableSet(action.plan.ownedFields || []));
    map.setIn(['userPostingStyle', 'unapplied'], ImmutableList(action.plan.unapplied || []));

    map.setIn(['userPostingStyle', 'status'], action.plan.selectedId ? 'applied' : 'idle');

    if (action.resetSuppressions) {
      map.setIn(['userPostingStyle', 'suppressions'], ImmutableSet());
    }

    applyDestination(map, state, action.plan, action.restoreParked === true);
    refreshIdempotency(map, state);
  });
}

export function reapplySelectedStyle(state, { respectManual, resetSuppressions }) {
  const selectedId = state.getIn(['userPostingStyle', 'selectedId']);
  const snapshot = state.getIn(['userPostingStyle', 'snapshot']);

  if (!selectedId || !snapshot || isExistingPostEdit(state)) {
    return state;
  }

  const basis = respectManual ? state : state.withMutations(map => {
    map.setIn(['userPostingStyle', 'manualFields'], ImmutableSet());
    map.setIn(['userPostingStyle', 'manualValues'], ImmutableMap());
  });
  const plan = resolveUserPostingStyle(snapshot, basis);

  if (plan.blocked) {
    return state;
  }

  const next = commitUserPostingStyle(basis, {
    plan,
    snapshot,
    resetSuppressions,
    restoreParked: true,
  });

  if (!respectManual) {
    return next;
  }

  return next.withMutations(restoreManualValues);
}

export function finishStyleDestination(state, action) {
  if (isExistingPostEdit(state)) {
    return state;
  }

  const style = state.get('userPostingStyle');

  if (!style || style.get('selectedId') !== action.selectedId || String(style.get('destinationAccountId') || '') !== String(action.accountId || '')) {
    return state;
  }

  const waiting = style.get('destinationStatus');

  if (waiting !== 'pending' && waiting !== 'needs_resolve') {
    return state;
  }

  if (action.status === 'pending') {
    return state
      .setIn(['userPostingStyle', 'destinationStatus'], 'pending')
      .setIn(['userPostingStyle', 'status'], 'applying');
  }

  if (action.status === 'ready') {
    return state.withMutations(map => {
      map.setIn(['userPostingStyle', 'destinationStatus'], 'ready');
      map.setIn(['userPostingStyle', 'status'], 'applied');
      map.setIn(['userPostingStyle', 'unapplied'], withoutDestination(map.getIn(['userPostingStyle', 'unapplied'])));
    });
  }

  if (action.status === 'failed') {
    return state.withMutations(map => {
      map.set('context', emptyComposerPostingContext());
      map.setIn(['userPostingStyle', 'destinationStatus'], 'failed');
      map.setIn(['userPostingStyle', 'status'], 'failed');
      map.setIn(['userPostingStyle', 'unapplied'], withDestination(map.getIn(['userPostingStyle', 'unapplied'])));
    });
  }

  return state;
}

export function toggleStyleHashtag(state, action) {
  if (isExistingPostEdit(state)) {
    return state;
  }

  const origin = action.origin === 'destination' ? 'destination' : 'style';
  const normalizedName = normalizeManagedHashtagName(action.normalizedName);
  const key = `${origin}:${normalizedName}`;
  const suppressed = state.getIn(['userPostingStyle', 'suppressions'], ImmutableSet());
  const next = suppressed.includes(key) ? suppressed.delete(key) : suppressed.add(key);
  const previousSignature = postingContextOutputSignature(state);
  const updated = state.setIn(['userPostingStyle', 'suppressions'], next).set('dirty', true);

  if (previousSignature === postingContextOutputSignature(updated)) {
    return updated;
  }

  return updated.set('idempotencyKey', uuid());
}

export function clearStyleManualState(state) {
  if (!state.get('userPostingStyle')) {
    return state;
  }

  return state.withMutations(map => {
    map.setIn(['userPostingStyle', 'manualFields'], ImmutableSet());
    map.setIn(['userPostingStyle', 'manualValues'], ImmutableMap());
    map.setIn(['userPostingStyle', 'unapplied'], ImmutableList());
    map.setIn(['userPostingStyle', 'suppressions'], ImmutableSet());
  });
}
