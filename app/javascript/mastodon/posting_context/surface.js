import { List as ImmutableList } from 'immutable';
import { normalizeManagedHashtagName } from './managed_hashtags';
import { isExistingPostEdit } from './materialize';
import { resolveUserPostingStyle } from './user_style_resolver';

// A portable composer surface names the screen the draft is attached to.
// composerId keeps the draft. The surface keeps the destination.

const read = (value, key) => {
  if (!value) {
    return undefined;
  }

  if (typeof value.get === 'function') {
    return value.get(key);
  }

  return value[key];
};

export function normalizeSurface(surface) {
  const kind = read(surface, 'kind');
  const key = read(surface, 'key');

  if (!kind || key === undefined || key === null || key === '') {
    return null;
  }

  return {
    kind,
    key: String(key),
  };
}

export function surfacesEqual(left, right) {
  const first = normalizeSurface(left);
  const second = normalizeSurface(right);

  if (!first && !second) {
    return true;
  }

  if (!first || !second) {
    return false;
  }

  return first.kind === second.kind && first.key === second.key;
}

const targetKind = style => (style && style.getIn ? (style.getIn(['target', 'kind']) || 'none') : 'none');

export function styleMatchesSurface(style, surface) {
  const normalized = normalizeSurface(surface);

  if (!style || !normalized) {
    return false;
  }

  const kind = targetKind(style);

  if (kind === 'none') {
    return true;
  }

  if (kind !== normalized.kind) {
    return false;
  }

  if (kind === 'group') {
    return String(style.getIn(['target', 'accountId']) || '') === normalized.key;
  }

  if (kind === 'hashtag') {
    return normalizeManagedHashtagName(style.getIn(['target', 'hashtag'])) === normalizeManagedHashtagName(normalized.key);
  }

  return false;
}

// Dedicated styles for this surface come first. Shared styles follow.
// A style aimed at a different destination is omitted.
export function selectPortablePostingStyleCandidates(styles, surface) {
  const normalized = normalizeSurface(surface);
  const list = styles && typeof styles.forEach === 'function' ? styles : ImmutableList();

  if (!normalized) {
    return ImmutableList();
  }

  const dedicated = [];
  const common = [];

  list.forEach(style => {
    const kind = targetKind(style);

    if (kind === 'none') {
      common.push(style);
      return;
    }

    if (styleMatchesSurface(style, normalized) && kind !== 'none') {
      dedicated.push(style);
    }
  });

  return ImmutableList(dedicated.concat(common));
}

export function composerDraftInProgress(composer) {
  if (!composer) {
    return false;
  }

  const text = String(composer.get('text') || '').trim();
  const media = composer.get('media_attachments');
  const poll = composer.get('poll');

  return text.length > 0
    || Boolean(media && media.size > 0)
    || (poll !== null && poll !== undefined)
    || Boolean(composer.get('in_reply_to'))
    || Boolean(composer.get('quote_from'));
}

export function portablePostingContextReady(composer) {
  const surface = normalizeSurface(composer && composer.get('surface'));

  if (!composer || !surface) {
    return false;
  }

  if (surface.kind === 'list') {
    return true;
  }

  if (surface.kind === 'group') {
    return String(composer.get('posting_context_account_id') || '') === surface.key
      && String(composer.getIn(['context', 'resolvedAccountId']) || '') === surface.key
      && Boolean(composer.getIn(['context', 'key']));
  }

  if (surface.kind === 'hashtag') {
    const tags = composer.getIn(['context', 'managed', 'hashtags']);
    const expected = normalizeManagedHashtagName(surface.key);

    return Boolean(tags && tags.some && tags.some(tag => (
      normalizeManagedHashtagName(tag.get('normalizedName') || tag.get('name')) === expected
    )));
  }

  return false;
}

export function lockedStyleViolatesComposer(composer, style) {
  const plan = resolveUserPostingStyle(style, composer, { destinationPolicy: 'locked' });

  if (!plan || plan.blocked || plan.needsConfirmation || (plan.unapplied && plan.unapplied.length > 0)) {
    return true;
  }

  if (!plan.destination || plan.destination.action !== 'keep' || plan.destination.changes || plan.destination.policy !== 'locked') {
    return true;
  }

  const privacy = Object.prototype.hasOwnProperty.call(plan.fields, 'privacy') ? plan.fields.privacy : composer.get('privacy');
  const allowed = composer.getIn(['context', 'constraints', 'allowedVisibilities']);

  if (allowed && typeof allowed.includes === 'function' && privacy && !allowed.includes(privacy)) {
    return true;
  }

  const prohibited = composer.get('prohibited_visibilities');

  if (prohibited && typeof prohibited.includes === 'function' && privacy && prohibited.includes(privacy)) {
    return true;
  }

  return false;
}

const selectionBlocksAuto = composer => {
  const origin = composer.getIn(['userPostingStyle', 'selectionOrigin']);

  return origin === 'automatic' || origin === 'manual' || origin === 'none';
};

// Exactly one dedicated style, and only when the draft has not been touched.
export function selectPortableAutoStyle(styles, composer) {
  if (!composer || !composer.get('surface') || isExistingPostEdit(composer)) {
    return null;
  }

  if (selectionBlocksAuto(composer) || composer.getIn(['userPostingStyle', 'styleInputLock']) || composer.get('surfaceMismatch')) {
    return null;
  }

  const manual = composer.getIn(['userPostingStyle', 'manualFields']);

  if ((manual && manual.size > 0) || composerDraftInProgress(composer) || !portablePostingContextReady(composer)) {
    return null;
  }

  const dedicated = selectPortablePostingStyleCandidates(styles, composer.get('surface'))
    .filter(style => targetKind(style) !== 'none');

  if (!dedicated || dedicated.size !== 1) {
    return null;
  }

  const style = dedicated.get(0);

  if (lockedStyleViolatesComposer(composer, style)) {
    return null;
  }

  return style;
}

const deliversToDestination = surface => Boolean(surface) && (surface.kind === 'group' || surface.kind === 'hashtag');

// Moving onto or off a Group or Hashtag changes where the draft would be sent.
// A List has no delivery target, so List-to-List only renames the surface.
export function destinationShift(current, incoming) {
  const from = normalizeSurface(current);
  const to = normalizeSurface(incoming);

  if (!from || surfacesEqual(from, to)) {
    return false;
  }

  if (from.kind === 'list' && to && to.kind === 'list') {
    return false;
  }

  return deliversToDestination(from) || deliversToDestination(to);
}

// Decides whether an incoming surface may replace the composer's context.
// Older epochs cannot roll a newer surface back.
export function surfaceApplyDecision(state, action) {
  if (!action.surface) {
    return { mode: 'legacy' };
  }

  const incoming = normalizeSurface(action.surface);

  if (!incoming) {
    return { mode: 'ignore' };
  }

  const epoch = Number(action.surfaceEpoch) || 0;
  const stored = Number(state.get('surfaceEpoch')) || 0;

  if (!action.forceSurface && epoch < stored) {
    return { mode: 'ignore' };
  }

  const current = normalizeSurface(state.get('surface'));
  const shift = destinationShift(current, incoming);

  if (action.forceSurface) {
    return {
      mode: action.hasPostingContext === false ? 'surface-only' : 'replace',
      incoming,
      accept: true,
      shift,
    };
  }

  const pending = state.get('surfaceMismatch') ? normalizeSurface(state.get('pendingSurface')) : null;

  if (pending && surfacesEqual(incoming, pending)) {
    return { mode: 'refresh-pending', incoming };
  }

  if (pending && current && surfacesEqual(incoming, current)) {
    return { mode: 'refresh-held', incoming };
  }

  if (pending) {
    return { mode: 'mismatch', incoming };
  }

  if (!current || surfacesEqual(incoming, current)) {
    return {
      mode: action.hasPostingContext === false ? 'surface-only' : 'apply',
      incoming,
      changed: !current,
      shift: false,
    };
  }

  if (shift && composerDraftInProgress(state)) {
    return { mode: 'mismatch', incoming, shift: true };
  }

  return {
    mode: action.hasPostingContext === false ? 'surface-only' : 'replace',
    incoming,
    shift,
  };
}
