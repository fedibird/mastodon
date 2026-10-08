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
  resolvedAccountId: null,
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
  destinationFailure: null,
  destinationAccountId: null,
  snapshot: null,
  styleOwnedFields: ImmutableSet(),
  unapplied: ImmutableList(),
  suppressions: ImmutableSet(),
  parkedContext: null,
  parkedPostingContextAccountId: null,
  parkedDestinationStatus: null,
  parkedDestinationFailure: null,
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
  map.setIn(['userPostingStyle', 'parkedPostingContextAccountId'], null);
  map.setIn(['userPostingStyle', 'parkedDestinationStatus'], null);
  map.setIn(['userPostingStyle', 'parkedDestinationFailure'], null);
  map.setIn(['userPostingStyle', 'parkedStyleId'], null);
};

const styleOwnsDestination = map => map.getIn(['userPostingStyle', 'destinationSource']) === 'style';

const styleAccountId = accountId => (
  accountId === null || accountId === undefined || accountId === '' ? null : String(accountId)
);

// A portable composer stores its target in the same field. Clear it only
// when this composer's style destination is the owner.
const clearStyleAccountIdentity = map => {
  if (!styleOwnsDestination(map)) {
    return;
  }

  map.set('posting_context_account_id', null);
};

const assignStyleAccountIdentity = (map, accountId) => {
  map.set('posting_context_account_id', styleAccountId(accountId));
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
  map.setIn(['userPostingStyle', 'parkedPostingContextAccountId'], map.get('posting_context_account_id'));
  map.setIn(['userPostingStyle', 'parkedDestinationStatus'], map.getIn(['userPostingStyle', 'destinationStatus']));
  map.setIn(['userPostingStyle', 'parkedDestinationFailure'], map.getIn(['userPostingStyle', 'destinationFailure']));
  map.setIn(['userPostingStyle', 'parkedStyleId'], map.getIn(['userPostingStyle', 'selectedId']));
  map.set('context', emptyComposerPostingContext());
  clearStyleAccountIdentity(map);
  map.setIn(['userPostingStyle', 'destinationStatus'], 'skipped');
  map.setIn(['userPostingStyle', 'unapplied'], withDestination(map.getIn(['userPostingStyle', 'unapplied'])));
}

export function abandonStyleDestination(map) {
  if (map.getIn(['userPostingStyle', 'destinationSource']) !== 'style') {
    return;
  }

  map.set('context', emptyComposerPostingContext());
  clearStyleAccountIdentity(map);
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
    const forced = map.get('spoiler') === true && String(map.get('spoiler_text') || '').trim() !== '';

    if (!forced) {
      map.set('sensitive', values.get('sensitive'));
    }
  }
};

const clearStyleContext = map => {
  if (!styleOwnsDestination(map)) {
    return;
  }

  map.set('context', emptyComposerPostingContext());
  clearStyleAccountIdentity(map);
};

const applyClearStyle = map => {
  clearStyleContext(map);
  map.setIn(['userPostingStyle', 'destinationSource'], null);
  map.setIn(['userPostingStyle', 'destinationStatus'], 'idle');
  map.setIn(['userPostingStyle', 'destinationFailure'], null);
  map.setIn(['userPostingStyle', 'destinationAccountId'], null);
  map.setIn(['userPostingStyle', 'status'], map.getIn(['userPostingStyle', 'selectedId']) ? 'applied' : 'idle');
  clearParkedDestination(map);
};

const applyHashtagDestination = map => {
  clearStyleContext(map);
  map.setIn(['userPostingStyle', 'destinationSource'], 'style');
  map.setIn(['userPostingStyle', 'destinationStatus'], 'ready');
  map.setIn(['userPostingStyle', 'destinationFailure'], null);
  map.setIn(['userPostingStyle', 'destinationAccountId'], null);
  map.setIn(['userPostingStyle', 'status'], 'applied');
  clearParkedDestination(map);
};

const parkedGroupIsReady = (previous, accountId) => {
  const parkedContext = previous.getIn(['userPostingStyle', 'parkedContext']);
  const parkedAccountId = previous.getIn(['userPostingStyle', 'parkedPostingContextAccountId']);
  const resolvedAccountId = parkedContext && parkedContext.get ? parkedContext.get('resolvedAccountId') : null;

  return previous.getIn(['userPostingStyle', 'parkedDestinationStatus']) === 'ready'
    && Boolean(parkedContext)
    && String(resolvedAccountId || '') === String(accountId || '')
    && String(parkedAccountId || '') === String(accountId || '');
};

const restoreParkedGroup = (map, previous, accountId) => {
  const parkedStatus = previous.getIn(['userPostingStyle', 'parkedDestinationStatus']) || 'ready';

  map.setIn(['userPostingStyle', 'destinationSource'], 'style');
  map.setIn(['userPostingStyle', 'destinationAccountId'], accountId);
  assignStyleAccountIdentity(map, accountId);

  if (parkedGroupIsReady(previous, accountId)) {
    map.set('context', previous.getIn(['userPostingStyle', 'parkedContext']));
    map.setIn(['userPostingStyle', 'destinationStatus'], 'ready');
    map.setIn(['userPostingStyle', 'destinationFailure'], null);
    map.setIn(['userPostingStyle', 'status'], 'applied');
    map.setIn(['userPostingStyle', 'unapplied'], withoutDestination(map.getIn(['userPostingStyle', 'unapplied'])));
    clearParkedDestination(map);
    return;
  }

  map.set('context', emptyComposerPostingContext());

  if (parkedStatus === 'failed') {
    map.setIn(['userPostingStyle', 'destinationStatus'], 'failed');
    map.setIn(['userPostingStyle', 'destinationFailure'], previous.getIn(['userPostingStyle', 'parkedDestinationFailure']) || 'error');
    map.setIn(['userPostingStyle', 'status'], 'failed');
    map.setIn(['userPostingStyle', 'unapplied'], withDestination(map.getIn(['userPostingStyle', 'unapplied'])));
    clearParkedDestination(map);
    return;
  }

  map.setIn(['userPostingStyle', 'destinationStatus'], 'needs_resolve');
  map.setIn(['userPostingStyle', 'destinationFailure'], null);
  map.setIn(['userPostingStyle', 'status'], 'applying');
  map.setIn(['userPostingStyle', 'unapplied'], withoutDestination(map.getIn(['userPostingStyle', 'unapplied'])));
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
    assignStyleAccountIdentity(map, accountId);
    return;
  }

  if (sameAccount && previous.getIn(['userPostingStyle', 'destinationStatus']) === 'failed') {
    map.set('context', emptyComposerPostingContext());
    map.setIn(['userPostingStyle', 'destinationSource'], 'style');
    map.setIn(['userPostingStyle', 'destinationAccountId'], accountId);
    assignStyleAccountIdentity(map, accountId);
    map.setIn(['userPostingStyle', 'destinationStatus'], 'pending');
    map.setIn(['userPostingStyle', 'destinationFailure'], null);
    map.setIn(['userPostingStyle', 'status'], 'applying');
    map.setIn(['userPostingStyle', 'unapplied'], withoutDestination(map.getIn(['userPostingStyle', 'unapplied'])));
    clearParkedDestination(map);
    return;
  }

  if (sameAccount && (previous.getIn(['userPostingStyle', 'destinationStatus']) === 'pending' || previous.getIn(['userPostingStyle', 'destinationStatus']) === 'needs_resolve')) {
    return;
  }

  map.set('context', emptyComposerPostingContext());
  map.setIn(['userPostingStyle', 'destinationSource'], 'style');
  map.setIn(['userPostingStyle', 'destinationAccountId'], accountId);
  assignStyleAccountIdentity(map, accountId);
  map.setIn(['userPostingStyle', 'destinationStatus'], restoreParked ? 'needs_resolve' : 'pending');
  map.setIn(['userPostingStyle', 'destinationFailure'], null);
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

export function beginStyleDestinationRetry(state) {
  if (isExistingPostEdit(state)) {
    return state;
  }

  const style = state.get('userPostingStyle');
  const snapshot = style && style.get('snapshot');
  const accountId = snapshot && snapshot.getIn(['target', 'accountId']);

  if (!style || style.get('destinationStatus') !== 'failed' || style.get('destinationSource') !== 'style') {
    return state;
  }

  if (!snapshot || snapshot.getIn(['target', 'kind']) !== 'group' || !accountId) {
    return state;
  }

  return state.withMutations(map => {
    map.set('context', emptyComposerPostingContext());
    map.setIn(['userPostingStyle', 'destinationStatus'], 'pending');
    map.setIn(['userPostingStyle', 'destinationFailure'], null);
    map.setIn(['userPostingStyle', 'destinationAccountId'], String(accountId));
    assignStyleAccountIdentity(map, accountId);
    map.setIn(['userPostingStyle', 'status'], 'applying');
    map.setIn(['userPostingStyle', 'unapplied'], withoutDestination(map.getIn(['userPostingStyle', 'unapplied'])));
  });
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
      .setIn(['userPostingStyle', 'destinationFailure'], null)
      .setIn(['userPostingStyle', 'status'], 'applying');
  }

  if (action.status === 'ready') {
    return state.withMutations(map => {
      map.setIn(['userPostingStyle', 'destinationStatus'], 'ready');
      map.setIn(['userPostingStyle', 'destinationFailure'], null);
      map.setIn(['userPostingStyle', 'status'], 'applied');
      map.setIn(['userPostingStyle', 'unapplied'], withoutDestination(map.getIn(['userPostingStyle', 'unapplied'])));
    });
  }

  if (action.status === 'failed') {
    return state.withMutations(map => {
      map.set('context', emptyComposerPostingContext());

      if (styleOwnsDestination(map)) {
        assignStyleAccountIdentity(map, action.accountId);
      }

      map.setIn(['userPostingStyle', 'destinationStatus'], 'failed');
      map.setIn(['userPostingStyle', 'destinationFailure'], action.failure === 'unsupported' ? 'unsupported' : 'error');
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

// The snapshot's explicit sensitive choice, when the current style still owns
// that field and the user has not edited it. Undefined when media changes
// should follow the normal composer rules.
export function explicitStyleSensitive(state) {
  const owned = state.getIn(['userPostingStyle', 'styleOwnedFields']);
  const manual = state.getIn(['userPostingStyle', 'manualFields']);

  if (!owned || !owned.includes || !owned.includes('sensitive')) {
    return undefined;
  }

  if (manual && manual.includes && manual.includes('sensitive')) {
    return undefined;
  }

  const defaults = state.getIn(['userPostingStyle', 'snapshot', 'defaults']);

  if (!defaults || !defaults.has || !defaults.has('sensitive')) {
    return undefined;
  }

  return defaults.get('sensitive') === true;
}

const spoilerTextForcesSensitive = state => (
  state.get('spoiler') === true && String(state.get('spoiler_text') || '').trim() !== ''
);

const manualSensitiveValue = state => {
  const manual = state.getIn(['userPostingStyle', 'manualFields']);

  if (!manual || !manual.includes || !manual.includes('sensitive')) {
    return undefined;
  }

  const stored = state.getIn(['userPostingStyle', 'manualValues', 'sensitive']);

  return stored === true || stored === false ? stored : undefined;
};

const ownSensitiveFromStyleWarning = (map, state) => {
  const manual = state.getIn(['userPostingStyle', 'manualFields']);
  const owned = state.getIn(['userPostingStyle', 'styleOwnedFields']);
  const styleWarning = Boolean(owned && owned.includes && owned.includes('spoiler'));

  if (styleWarning && !(manual && manual.includes && manual.includes('sensitive'))) {
    map.updateIn(['userPostingStyle', 'styleOwnedFields'], set => (set || ImmutableSet()).add('sensitive'));
  }
};

const warningTextPresent = text => String(text || '').trim() !== '';

// Media plus the account default, matching the value a normal composer
// would show when no person and no style has chosen sensitive.
const derivedComposerSensitive = state => {
  const media = state.get('media_attachments');

  return Boolean(media && media.size > 0) && state.get('default_sensitive') === true;
};

// The server stores sensitive when the warning text is non-blank. Forcing that
// on does not count as a manual choice. Once the text is empty again, restore
// the manual value, then the style's explicit value, then the composer default.
export function syncSensitiveWithWarning(map, state, { spoiler, spoilerText }) {
  if (spoiler === true && warningTextPresent(spoilerText)) {
    map.set('sensitive', true);
    ownSensitiveFromStyleWarning(map, state);
    return true;
  }

  const manualValue = manualSensitiveValue(state);

  if (manualValue === true || manualValue === false) {
    map.set('sensitive', manualValue);
    return true;
  }

  const explicit = explicitStyleSensitive(state);

  if (explicit === true || explicit === false) {
    map.set('sensitive', explicit);
    return true;
  }

  const forcedBefore = state.get('spoiler') === true && warningTextPresent(state.get('spoiler_text'));

  if (forcedBefore && !warningTextPresent(spoilerText)) {
    map.set('sensitive', derivedComposerSensitive(state));
    return true;
  }

  return false;
}

export function applySensitiveOnFirstMedia(map, state) {
  if (spoilerTextForcesSensitive(state)) {
    map.set('sensitive', true);
    ownSensitiveFromStyleWarning(map, state);
    return;
  }

  const manualValue = manualSensitiveValue(state);

  if (manualValue === true || manualValue === false) {
    map.set('sensitive', manualValue);
    return;
  }

  const explicit = explicitStyleSensitive(state);
  const spoilerOn = state.get('spoiler') === true;

  if (explicit === false) {
    return;
  }

  if (explicit === true || state.get('default_sensitive') || spoilerOn) {
    map.set('sensitive', true);

    if (spoilerOn) {
      ownSensitiveFromStyleWarning(map, state);
    }
  }
}

export function applySensitiveOnLastMediaRemoved(map, state) {
  const manual = state.getIn(['userPostingStyle', 'manualFields']);
  const manualSensitive = Boolean(manual && manual.includes && manual.includes('sensitive'));
  const owned = state.getIn(['userPostingStyle', 'styleOwnedFields']);
  const styleInvolved = Boolean(owned && owned.includes && (owned.includes('spoiler') || owned.includes('sensitive')));

  if (!manualSensitive && spoilerTextForcesSensitive(state) && styleInvolved) {
    map.set('sensitive', true);
    return;
  }

  map.set('sensitive', false);
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
