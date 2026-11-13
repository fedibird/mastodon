import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet, fromJS } from 'immutable';
import { initialSenderIdentity, sessionPostingIdentityId } from '../posting_identity/identity';
import { assignmentSurface, composerDraftInProgress, destinationShift, surfacesEqual } from '../posting_context/surface';
import { initialUserPostingStyle } from '../posting_context/user_style_state';

export const COMPOSER_DRAFT_SCHEMA_VERSION = 1;

const TRANSIENT_INPUT_KEYS = [
  'suggestions',
  'suggestion_token',
  'is_submitting',
  'is_uploading',
  'is_processing',
  'progress',
  'idempotency_key',
  'instance_id',
  'draft_generation',
  'html',
  'materialized_text',
];

function asArray (value) {
  if (!value) {
    return [];
  }

  if (typeof value.toArray === 'function') {
    return value.toArray();
  }

  if (Array.isArray(value)) {
    return value;
  }

  return [];
}

function stringOrNull (value) {
  if (value === null || value === undefined || value === '') {
    return null;
  }

  return String(value);
}

function booleanValue (value) {
  return value === true;
}

function numberOrNull (value) {
  if (value === null || value === undefined || value === '') {
    return null;
  }

  const number = Number(value);

  return Number.isFinite(number) ? number : null;
}

function plainValue (value) {
  if (!value) {
    return null;
  }

  if (typeof value.toJS === 'function') {
    return value.toJS();
  }

  return value;
}

function plainRecord (value, fields) {
  if (!value) {
    return null;
  }

  const read = (key) => (typeof value.get === 'function' ? value.get(key) : value[key]);
  const record = {};

  fields.forEach((field) => {
    record[field] = read(field) === undefined ? null : read(field);
  });

  return record;
}

function plainList (value, fields) {
  return asArray(value).map(item => plainRecord(item, fields)).filter(Boolean);
}

function sortedStrings (value) {
  return asArray(value).map(item => String(item)).filter(Boolean).sort();
}

export function draftCaptureBlock (composer) {
  if (!composer || typeof composer.get !== 'function') {
    return 'missing';
  }

  if (composer.get('id') !== null && composer.get('id') !== undefined) {
    return 'existing_edit';
  }

  if (composer.get('scheduled_status_id') !== null && composer.get('scheduled_status_id') !== undefined) {
    return 'scheduled_edit';
  }

  if (composer.get('redraftMediaUnconfirmed') === true) {
    return 'redraft';
  }

  return null;
}

function manualFields (composer) {
  const fields = composer.getIn(['userPostingStyle', 'manualFields']);

  return fields && typeof fields.size === 'number' ? fields : ImmutableSet();
}

// Opening a composer, or landing on a surface that fills destination context,
// is not a draft. A draft starts when the user has entered something.
export function composerDraftHasPersistableInput (composer) {
  if (!composer || typeof composer.get !== 'function') {
    return false;
  }

  if (composerDraftInProgress(composer)) {
    return true;
  }

  if (String(composer.get('spoiler_text') || '').trim() !== '') {
    return true;
  }

  if (manualFields(composer).size > 0) {
    return true;
  }

  if (composer.get('searchability_manual') === true || composer.get('circle_id')) {
    return true;
  }

  if (composer.get('references') && composer.get('references').size > 0) {
    return true;
  }

  if (composer.get('scheduled')) {
    return true;
  }

  if (composer.getIn(['senderIdentity', 'selectionOrigin']) === 'explicit') {
    return true;
  }

  const expires = composer.get('expires');
  const defaultExpires = composer.get('default_expires_in', null);

  return Boolean(expires) && expires !== defaultExpires;
}

export function composerDraftMediaIncomplete (composer) {
  if (!composer || typeof composer.get !== 'function') {
    return false;
  }

  const requests = composer.get('uploadRequests');

  return (composer.get('pending_media_attachments') || 0) > 0
    || composer.get('is_uploading') === true
    || composer.get('is_processing') === true
    || Boolean(requests && requests.size > 0);
}

function styleSnapshot (composer) {
  const snapshot = composer.getIn(['userPostingStyle', 'snapshot']);

  if (!snapshot) {
    return null;
  }

  const read = (key) => (typeof snapshot.get === 'function' ? snapshot.get(key) : snapshot[key]);
  const target = read('target');
  const defaults = read('defaults');

  return {
    id: stringOrNull(read('id')),
    name: read('name') ? String(read('name')) : '',
    revision: numberOrNull(read('revision')),
    target: plainValue(target),
    defaults: plainValue(defaults),
    managed: {
      hashtags: plainList(typeof snapshot.getIn === 'function' ? snapshot.getIn(['managed', 'hashtags']) : null, ['name', 'normalizedName', 'enforcement', 'ruleId']),
      mentions: plainList(typeof snapshot.getIn === 'function' ? snapshot.getIn(['managed', 'mentions']) : null, ['accountId', 'acct', 'enforcement', 'ruleId', 'placement']),
    },
  };
}

function contextSnapshot (composer) {
  const context = composer.get('context');

  if (!context || typeof context.get !== 'function') {
    return null;
  }

  const source = context.get('source');

  return {
    key: stringOrNull(context.get('key')),
    resolved_account_id: stringOrNull(context.get('resolvedAccountId')),
    source: source ? {
      id: stringOrNull(source.get('id')),
      revision: numberOrNull(source.get('revision')),
    } : null,
    managed: {
      hashtags: plainList(context.getIn(['managed', 'hashtags']), ['name', 'normalizedName', 'enforcement', 'ruleId']),
      mentions: plainList(context.getIn(['managed', 'mentions']), ['accountId', 'acct', 'enforcement', 'ruleId', 'placement']),
    },
    suppressions: {
      hashtags: sortedStrings(context.getIn(['suppressions', 'hashtags'])),
    },
    requirements: {
      following_accounts: plainList(context.getIn(['requirements', 'followingAccounts']), ['accountId', 'acct', 'enforcement', 'ruleId']),
    },
    constraints: {
      allowed_visibilities: context.getIn(['constraints', 'allowedVisibilities'])
        ? sortedStrings(context.getIn(['constraints', 'allowedVisibilities']))
        : null,
    },
    protocol: {
      activity_pub: {
        audience: plainRecord(context.getIn(['protocol', 'activityPub', 'audience']), ['accountId', 'acct', 'enforcement', 'ruleId']),
      },
    },
  };
}

function mediaSnapshot (composer) {
  return asArray(composer.get('media_attachments')).map((item, index) => {
    const id = typeof item.get === 'function' ? item.get('id') : item.id;

    if (id === null || id === undefined || id === '') {
      return null;
    }

    const read = (key) => (typeof item.get === 'function' ? item.get(key) : item[key]);
    const focusX = typeof item.getIn === 'function' ? item.getIn(['meta', 'focus', 'x']) : null;
    const focusY = typeof item.getIn === 'function' ? item.getIn(['meta', 'focus', 'y']) : null;

    return {
      id: String(id),
      order: read('order') === null || read('order') === undefined ? index : Number(read('order')),
      description: read('description') ? String(read('description')) : '',
      focus: {
        x: numberOrNull(focusX) || 0,
        y: numberOrNull(focusY) || 0,
      },
    };
  }).filter(Boolean).sort((left, right) => left.order - right.order || left.id.localeCompare(right.id));
}

function pollSnapshot (composer) {
  const poll = composer.get('poll');

  if (!poll || typeof poll.get !== 'function') {
    return null;
  }

  return {
    options: asArray(poll.get('options')).map(option => String(option)),
    expires_in: numberOrNull(poll.get('expires_in')),
    multiple: booleanValue(poll.get('multiple')),
  };
}

function surfaceSnapshot (composer) {
  const surface = composer.get('surface');

  if (!surface || typeof surface.get !== 'function' || !surface.get('kind') || !surface.get('key')) {
    return null;
  }

  return {
    kind: String(surface.get('kind')),
    key: String(surface.get('key')),
  };
}

function styleInput (composer) {
  const style = composer.get('userPostingStyle');

  if (!style || typeof style.get !== 'function') {
    return null;
  }

  const destinationStatus = style.get('destinationStatus') || 'idle';

  return {
    selected_id: stringOrNull(style.get('selectedId')),
    applied_revision: numberOrNull(style.get('appliedRevision')),
    usage_mode: style.get('usageMode') || 'usual',
    selection_kind: style.get('selectionKind') || 'pending',
    selection_origin: stringOrNull(style.get('selectionOrigin')),
    manual_fields: sortedStrings(style.get('manualFields')),
    manual_values: style.get('manualValues') && typeof style.get('manualValues').toJS === 'function'
      ? style.get('manualValues').toJS()
      : {},
    suppressions: sortedStrings(style.get('suppressions')),
    style_owned_fields: sortedStrings(style.get('styleOwnedFields')),
    unapplied: asArray(style.get('unapplied')).map(item => String(item)),
    destination_source: stringOrNull(style.get('destinationSource')),
    destination_policy: stringOrNull(style.get('destinationPolicy')),
    destination_account_id: stringOrNull(style.get('destinationAccountId')),
    destination_status: destinationStatus === 'failed' ? 'needs_resolve' : destinationStatus,
    snapshot: styleSnapshot(composer),
  };
}

export function composerDraftInput (composer) {
  return {
    text: String(composer.get('text') || ''),
    spoiler: booleanValue(composer.get('spoiler')),
    spoiler_text: String(composer.get('spoiler_text') || ''),
    privacy: stringOrNull(composer.get('privacy')),
    searchability: stringOrNull(composer.get('searchability')),
    searchability_manual: booleanValue(composer.get('searchability_manual')),
    searchability_desired: stringOrNull(composer.get('searchability_desired')),
    privacy_before_searchability: stringOrNull(composer.get('privacy_before_searchability')),
    circle_id: stringOrNull(composer.get('circle_id')),
    language: stringOrNull(composer.get('language')),
    sensitive: booleanValue(composer.get('sensitive')),
    in_reply_to_id: stringOrNull(composer.get('in_reply_to')),
    quote_id: stringOrNull(composer.get('quote_from')),
    quote_url: stringOrNull(composer.get('quote_from_url')),
    references: sortedStrings(composer.get('references')),
    context_references: sortedStrings(composer.get('context_references')),
    ignore_reference_check: booleanValue(composer.get('ignore_reference_check')),
    poll: pollSnapshot(composer),
    scheduled: stringOrNull(composer.get('scheduled')),
    expires: stringOrNull(composer.get('expires')),
    expires_action: stringOrNull(composer.get('expires_action')),
    media: mediaSnapshot(composer),
    context: contextSnapshot(composer),
    posting_context_account_id: stringOrNull(composer.get('posting_context_account_id')),
    surface: surfaceSnapshot(composer),
    user_posting_style: styleInput(composer),
    sender: {
      id: stringOrNull(composer.getIn(['senderIdentity', 'id'])),
      selection_origin: stringOrNull(composer.getIn(['senderIdentity', 'selectionOrigin'])),
    },
  };
}

export function stableStringify (value) {
  if (Array.isArray(value)) {
    return `[${value.map(item => stableStringify(item)).join(',')}]`;
  }

  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(',')}}`;
  }

  return JSON.stringify(value === undefined ? null : value);
}

export function composerDraftRestoreBlocks (composer) {
  if (!composer || typeof composer.get !== 'function') {
    return { media: false, reply: null, quote: null };
  }

  const media = composer.get('media_attachments');

  return {
    media: Boolean(media && typeof media.some === 'function' && media.some(item => item.get('unresolved') === true)),
    reply: composer.get('draftReplyHold') || null,
    quote: composer.get('draftQuoteHold') || null,
  };
}

export function composerDraftRestoreBlocksSubmit (composer) {
  const blocks = composerDraftRestoreBlocks(composer);

  return blocks.media || blocks.reply === 'pending' || blocks.reply === 'failed' || blocks.quote === 'pending' || blocks.quote === 'failed';
}

function postingContextFromComposer (composer) {
  const context = contextSnapshot(composer);

  if (!context || !context.key) {
    return null;
  }

  const audience = context.protocol && context.protocol.activity_pub && context.protocol.activity_pub.audience;

  return {
    key: context.key,
    source: context.source,
    managed: {
      hashtags: context.managed.hashtags,
      mentions: context.managed.mentions,
    },
    requirements: {
      followingAccounts: (context.requirements && context.requirements.following_accounts) || [],
    },
    constraints: {
      allowedVisibilities: context.constraints && context.constraints.allowed_visibilities,
    },
    protocol: {
      activityPub: {
        audience: audience || null,
      },
    },
  };
}

function restoreSurfaceConflict (composer, input) {
  const screen = assignmentSurface(composer.get('displayedSurface')) || assignmentSurface(composer.get('surface'));
  const draft = assignmentSurface(input && input.surface);

  if (surfacesEqual(screen, draft)) {
    return { mode: 'same' };
  }

  if (!screen && draft && (draft.kind === 'group' || draft.kind === 'hashtag')) {
    return { mode: 'confirm' };
  }

  if (!screen || !(destinationShift(draft, screen) || destinationShift(screen, draft))) {
    return { mode: 'same' };
  }

  return { mode: 'mismatch', screen };
}

export function composerDraftContentHash (input, mediaIncomplete) {
  return stableStringify({ input, media_incomplete: mediaIncomplete === true });
}

export function snapshotComposerDraft (composer, meta = {}) {
  if (draftCaptureBlock(composer) || !composerDraftHasPersistableInput(composer)) {
    return null;
  }

  if (!meta.accountId || !meta.clientDraftUuid) {
    return null;
  }

  const mediaIncomplete = composerDraftMediaIncomplete(composer);
  const input = composerDraftInput(composer);

  return {
    schema_version: COMPOSER_DRAFT_SCHEMA_VERSION,
    account_id: String(meta.accountId),
    client_draft_uuid: String(meta.clientDraftUuid),
    composer_id: meta.composerId ? String(meta.composerId) : null,
    saved_at: meta.savedAt || null,
    media_incomplete: mediaIncomplete,
    content_hash: composerDraftContentHash(input, mediaIncomplete),
    input,
  };
}

function isPlainObject (value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function normalizeSnapshot (snapshot) {
  const input = { ...snapshot.input };

  TRANSIENT_INPUT_KEYS.forEach((key) => {
    delete input[key];
  });

  input.text = String(input.text);
  input.media = Array.isArray(input.media) ? input.media.filter(item => item && item.id).map(item => ({
    id: String(item.id),
    order: numberOrNull(item.order) || 0,
    description: item.description ? String(item.description) : '',
    focus: {
      x: numberOrNull(item.focus && item.focus.x) || 0,
      y: numberOrNull(item.focus && item.focus.y) || 0,
    },
  })) : [];

  const normalized = {
    schema_version: COMPOSER_DRAFT_SCHEMA_VERSION,
    account_id: String(snapshot.account_id),
    client_draft_uuid: String(snapshot.client_draft_uuid),
    composer_id: snapshot.composer_id ? String(snapshot.composer_id) : null,
    saved_at: snapshot.saved_at || null,
    media_incomplete: snapshot.media_incomplete === true,
    input,
  };

  normalized.content_hash = composerDraftContentHash(normalized.input, normalized.media_incomplete);

  return normalized;
}

export function restoreComposerDraft (value) {
  let snapshot = value;

  if (typeof value === 'string') {
    try {
      snapshot = JSON.parse(value);
    } catch (_error) {
      return { ok: false, reason: 'invalid_json' };
    }
  }

  if (!isPlainObject(snapshot)) {
    return { ok: false, reason: 'invalid_snapshot' };
  }

  if (snapshot.schema_version !== COMPOSER_DRAFT_SCHEMA_VERSION) {
    return { ok: false, reason: 'unsupported_schema' };
  }

  if (!snapshot.account_id || !snapshot.client_draft_uuid || !isPlainObject(snapshot.input) || typeof snapshot.input.text !== 'string') {
    return { ok: false, reason: 'invalid_snapshot' };
  }

  return { ok: true, snapshot: normalizeSnapshot(snapshot) };
}

function deepFreeze (value) {
  if (!value || typeof value !== 'object' || Object.isFrozen(value)) {
    return value;
  }

  Object.keys(value).forEach(key => deepFreeze(value[key]));

  return Object.freeze(value);
}

// Read-only copy of the same raw snapshot. A future preflight may inspect
// this copy. It must not write the copy back, and this module does not run
// preflight checks or rewrite the draft.
export function copyComposerDraftSnapshot (value) {
  const restored = restoreComposerDraft(value);

  if (!restored.ok) {
    return null;
  }

  return deepFreeze(JSON.parse(JSON.stringify(restored.snapshot)));
}

function listOf (items, fields) {
  return ImmutableList((items || []).filter(isPlainObject).map(item => ImmutableMap(fields.reduce((record, field) => {
    record[field] = item[field] === undefined ? null : item[field];

    return record;
  }, {}))));
}

function restoredContext (input) {
  const context = input.context || {};
  const managed = context.managed || {};
  const protocol = context.protocol || {};
  const activityPub = protocol.activity_pub || {};
  const audience = activityPub.audience;

  return ImmutableMap({
    key: stringOrNull(context.key),
    resolvedAccountId: stringOrNull(context.resolved_account_id),
    source: context.source ? ImmutableMap({
      id: stringOrNull(context.source.id),
      revision: numberOrNull(context.source.revision),
    }) : null,
    managed: ImmutableMap({
      hashtags: listOf(managed.hashtags, ['name', 'normalizedName', 'enforcement', 'ruleId']),
      mentions: listOf(managed.mentions, ['accountId', 'acct', 'enforcement', 'ruleId', 'placement']),
    }),
    suppressions: ImmutableMap({
      hashtags: ImmutableSet(context.suppressions && context.suppressions.hashtags || []),
    }),
    requirements: ImmutableMap({
      followingAccounts: listOf(context.requirements && context.requirements.following_accounts, ['accountId', 'acct', 'enforcement', 'ruleId']),
    }),
    constraints: ImmutableMap({
      allowedVisibilities: context.constraints && Array.isArray(context.constraints.allowed_visibilities)
        ? ImmutableSet(context.constraints.allowed_visibilities)
        : null,
    }),
    protocol: ImmutableMap({
      activityPub: ImmutableMap({
        audience: audience ? ImmutableMap({
          accountId: stringOrNull(audience.accountId),
          acct: audience.acct ? String(audience.acct).replace(/^@+/u, '') : null,
          enforcement: audience.enforcement || null,
          ruleId: audience.ruleId || null,
        }) : null,
      }),
    }),
  });
}

function restoredStyle (input, previous) {
  const style = input.user_posting_style || {};
  const base = initialUserPostingStyle();
  const manualValues = isPlainObject(style.manual_values) ? style.manual_values : {};

  return base.merge({
    selectedId: stringOrNull(style.selected_id),
    appliedRevision: numberOrNull(style.applied_revision),
    status: style.selected_id ? 'applied' : 'idle',
    manualFields: ImmutableSet(style.manual_fields || []),
    manualValues: fromJS(manualValues),
    suppressions: ImmutableSet(style.suppressions || []),
    styleOwnedFields: ImmutableSet(style.style_owned_fields || []),
    unapplied: ImmutableList(style.unapplied || []),
    destinationSource: stringOrNull(style.destination_source),
    destinationPolicy: stringOrNull(style.destination_policy),
    destinationAccountId: stringOrNull(style.destination_account_id),
    destinationStatus: style.destination_status || 'idle',
    snapshot: style.snapshot ? fromJS(style.snapshot) : null,
    selectionOrigin: stringOrNull(style.selection_origin),
    usageMode: style.usage_mode || 'usual',
    selectionKind: style.selection_kind || 'pending',
    selectionGeneration: (Number(previous && previous.get('selectionGeneration')) || 0) + 1,
    styleInputLock: true,
    destinationFailure: null,
  });
}

function restoredSender (input, previous) {
  const sender = input.sender || {};
  const sessionId = sessionPostingIdentityId();
  const requestedId = stringOrNull(sender.id);
  const epoch = (Number(previous && previous.get('changeEpoch')) || 0) + 1;

  if (!requestedId || requestedId === sessionId) {
    return initialSenderIdentity().set('changeEpoch', epoch);
  }

  return ImmutableMap({
    id: requestedId,
    selectionOrigin: sender.selection_origin || 'explicit',
    status: 'ready',
    changeEpoch: epoch,
    switchBlockReason: null,
  });
}

export function applyComposerDraft (state, snapshot, options = {}) {
  const restored = snapshot && snapshot.input ? { ok: true, snapshot } : restoreComposerDraft(snapshot);

  if (!restored.ok || draftCaptureBlock(state) || composerDraftHasPersistableInput(state)) {
    return state;
  }

  const input = restored.snapshot.input;
  const conflict = restoreSurfaceConflict(state, input);
  const heldSurface = conflict.mode === 'mismatch' ? conflict.screen : null;
  const heldContext = heldSurface ? postingContextFromComposer(state) : null;
  const nextEpoch = (Number(state.get('surfaceEpoch')) || 0) + 1;
  const media = ImmutableList((input.media || []).map(item => ImmutableMap({
    id: String(item.id),
    description: item.description || '',
    order: item.order,
    unresolved: true,
    meta: ImmutableMap({
      focus: ImmutableMap({
        x: item.focus.x,
        y: item.focus.y,
      }),
    }),
  })));
  const poll = input.poll ? ImmutableMap({
    options: ImmutableList((input.poll.options || []).map(option => String(option))),
    expires_in: numberOrNull(input.poll.expires_in),
    multiple: input.poll.multiple === true,
  }) : null;

  return state.withMutations((map) => {
    map.set('text', input.text);
    map.set('spoiler', input.spoiler === true);
    map.set('spoiler_text', input.spoiler_text ? String(input.spoiler_text) : '');
    map.set('privacy', input.privacy || state.get('privacy'));
    map.set('searchability', input.searchability || state.get('searchability'));
    map.set('searchability_manual', input.searchability_manual === true);
    map.set('searchability_desired', input.searchability_desired || null);
    map.set('privacy_before_searchability', input.privacy_before_searchability || null);
    map.set('circle_id', input.circle_id || null);
    map.set('language', input.language || state.get('language'));
    map.set('sensitive', input.sensitive === true);
    map.set('in_reply_to', input.in_reply_to_id || null);
    map.set('quote_from', input.quote_id || null);
    map.set('quote_from_url', input.quote_url || null);
    map.set('reply_status', null);
    map.set('references', ImmutableSet(input.references || []));
    map.set('context_references', ImmutableSet(input.context_references || []));
    map.set('ignore_reference_check', input.ignore_reference_check === true);
    map.set('poll', poll);
    map.set('scheduled', input.scheduled || null);
    map.set('expires', input.expires || state.get('expires'));
    map.set('expires_action', input.expires_action || state.get('expires_action'));
    map.set('media_attachments', media);
    map.set('draftReplyHold', input.in_reply_to_id ? 'pending' : null);
    map.set('draftQuoteHold', input.quote_id ? 'pending' : null);
    map.set('draftRestoreToken', options.restoreToken || null);
    map.set('draftSurfaceUnconfirmed', conflict.mode === 'confirm');
    map.set('context', input.context ? restoredContext(input) : state.get('context'));
    map.set('posting_context_account_id', input.posting_context_account_id || null);
    map.set('surface', input.surface ? ImmutableMap({ kind: input.surface.kind, key: String(input.surface.key) }) : null);
    map.set('surfaceMismatch', conflict.mode !== 'same');
    map.set('pendingSurface', heldSurface ? ImmutableMap({
      kind: heldSurface.kind,
      key: heldSurface.key,
      postingContext: heldContext,
      postingContextAccountId: state.get('posting_context_account_id') || null,
      hasPostingContext: Boolean(heldContext),
      surfaceEpoch: nextEpoch,
    }) : null);
    map.set('displayedSurface', heldSurface ? ImmutableMap({
      kind: heldSurface.kind,
      key: heldSurface.key,
      surfaceEpoch: nextEpoch,
    }) : null);
    map.set('surfaceEpoch', nextEpoch);
    map.set('userPostingStyle', restoredStyle(input, state.get('userPostingStyle')));
    map.set('senderIdentity', restoredSender(input, state.get('senderIdentity')));
    map.set('id', null);
    map.set('scheduled_status_id', null);
    map.set('dirty', true);
    map.set('is_submitting', false);
    map.set('is_uploading', false);
    map.set('is_processing', false);
    map.set('is_changing_upload', false);
    map.set('activeSubmitId', null);
    map.set('progress', 0);
    map.set('pending_media_attachments', 0);
    map.set('pending_exclusive_attachments', 0);
    map.set('processing_media_attachments', 0);
    map.set('uploadRequests', ImmutableMap());
    map.set('suggestions', ImmutableList());
    map.set('suggestion_token', null);
    map.set('interactionCheck', null);
    map.set('focusDate', null);
    map.set('caretPosition', null);
    map.set('preselectDate', null);
    map.set('redraftMediaUnconfirmed', false);
    map.update('redraftEpoch', epoch => (epoch || 0) + 1);
    map.set('idempotencyKey', options.idempotencyKey || null);
    map.set('is_composing', state.get('is_composing'));
  });
}
