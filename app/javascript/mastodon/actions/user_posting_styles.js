import { fromJS } from 'immutable';
import api from '../api';
import { targetComposerAction } from './composer';
import { refreshComposerGroupDiscovery, scheduleComposerInteractionCheck } from './posting_identities';
import { isExistingPostEdit } from '../posting_context/materialize';
import { normalizeUserPostingStyle, resolveUserPostingStyle } from '../posting_context/user_style_resolver';
import { composerDraftInProgress, portablePostingContextReady, styleMatchesSurface, surfaceCacheKey, surfacesEqual } from '../posting_context/surface';
import { decideUsualSelection } from '../posting_context/usual_selection';
import { selectComposer } from '../selectors/composer';
import { fetchGlobalUsualStyle, fetchUserPostingContextAssignment, saveGlobalUsualStyle } from './user_posting_context_assignments';

export const USER_POSTING_STYLES_FETCH_REQUEST = 'USER_POSTING_STYLES_FETCH_REQUEST';
export const USER_POSTING_STYLES_FETCH_SUCCESS = 'USER_POSTING_STYLES_FETCH_SUCCESS';
export const USER_POSTING_STYLES_FETCH_FAIL = 'USER_POSTING_STYLES_FETCH_FAIL';
export const USER_POSTING_STYLE_COMMIT = 'USER_POSTING_STYLE_COMMIT';
export const USER_POSTING_STYLE_DESTINATION = 'USER_POSTING_STYLE_DESTINATION';
export const USER_POSTING_STYLE_DESTINATION_RETRY = 'USER_POSTING_STYLE_DESTINATION_RETRY';
export const USER_POSTING_STYLE_HASHTAG_TOGGLE = 'USER_POSTING_STYLE_HASHTAG_TOGGLE';
export const USER_POSTING_STYLE_AUTO_ATTEMPT = 'USER_POSTING_STYLE_AUTO_ATTEMPT';
export const USER_POSTING_STYLE_DEFAULTS_SETTLED = 'USER_POSTING_STYLE_DEFAULTS_SETTLED';
export const USER_POSTING_STYLE_RESOLUTION = 'USER_POSTING_STYLE_RESOLUTION';
export const USER_POSTING_STYLE_USAGE = 'USER_POSTING_STYLE_USAGE';

const selectStyle = (state, styleId) => {
  const styles = state.getIn(['userPostingStyles', 'styles']);

  if (!styles || !styles.find) {
    return null;
  }

  return styles.find(style => style.get('id') === String(styleId)) || null;
};

const stillWaiting = (getState, composerId, selectedId, accountId) => {
  const composer = selectComposer(getState(), composerId);

  if (!composer || isExistingPostEdit(composer) || composer.get('in_reply_to') || composer.get('quote_from')) {
    return false;
  }

  const status = composer.getIn(['userPostingStyle', 'destinationStatus']);

  return composer.getIn(['userPostingStyle', 'selectedId']) === selectedId
    && String(composer.getIn(['userPostingStyle', 'destinationAccountId'] || '')) === String(accountId)
    && (status === 'pending' || status === 'needs_resolve');
};

const destinationResult = (composerId, payload) => targetComposerAction({
  type: USER_POSTING_STYLE_DESTINATION,
  ...payload,
}, composerId);

let catalogRequestId = 0;

export function fetchUserPostingStyles({ force = false } = {}) {
  return (dispatch, getState) => {
    const status = getState().getIn(['userPostingStyles', 'status']);

    if (!force && ['loading', 'ready', 'failed'].includes(status)) {
      return Promise.resolve();
    }

    const requestId = ++catalogRequestId;
    dispatch({ type: USER_POSTING_STYLES_FETCH_REQUEST, requestId, skipLoading: true });

    return api(getState)
      .get('/api/v1/fedibird/user_posting_contexts')
      .then(({ data }) => {
        if (!Array.isArray(data)) throw new Error('Invalid posting styles catalog');
        const styles = data.map(style => fromJS(normalizeUserPostingStyle(style)));

        dispatch({
          type: USER_POSTING_STYLES_FETCH_SUCCESS,
          requestId,
          styles,
          skipLoading: true,
        });
      })
      .catch(error => {
        dispatch({
          type: USER_POSTING_STYLES_FETCH_FAIL,
          requestId,
          error,
          skipLoading: true,
          skipAlert: true,
        });
      });
  };
}

const destinationLocked = composer => (
  Boolean(composer && (composer.get('surface') || composer.getIn(['userPostingStyle', 'destinationPolicy']) === 'locked'))
);

export function loadUserPostingStyleDestination(composerId, { selectedId, accountId, force = false }) {
  return (dispatch, getState) => {
    const started = selectComposer(getState(), composerId);

    if (destinationLocked(started) || !stillWaiting(getState, composerId, selectedId, accountId)) {
      return Promise.resolve();
    }

    return dispatch(refreshComposerGroupDiscovery(composerId, accountId, {
      force,
      selectedId,
      surfaceEpoch: started.get('surfaceEpoch') || 0,
    }));
  };
}

export function commitUserPostingStyle(composerId, styleId, { selectionOrigin, expectedSurface, usageMode, selectionKind, resolutionScope, revalidateUsual } = {}) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);

    if (!composer || isExistingPostEdit(composer)) {
      return Promise.resolve();
    }

    const style = styleId === null || styleId === undefined ? null : selectStyle(getState(), styleId);

    if (styleId !== null && styleId !== undefined && !style) {
      return Promise.resolve();
    }

    const surface = composer.get('surface');
    const destinationPolicy = surface ? 'locked' : 'change';

    // The surface at confirmation time has to be the surface being confirmed.
    // A locked composer also refuses a style aimed at a different destination,
    // and refuses every apply while the draft still belongs to the previous one.
    if (destinationPolicy === 'locked') {
      if (composer.get('surfaceMismatch')) {
        return Promise.resolve();
      }

      if (expectedSurface !== undefined && !surfacesEqual(expectedSurface, surface)) {
        return Promise.resolve();
      }

      if (style && !styleMatchesSurface(style, surface)) {
        return Promise.resolve();
      }
    }

    const plan = resolveUserPostingStyle(style, composer, { destinationPolicy });

    if (plan.blocked) {
      return Promise.resolve();
    }

    const retryingDiscovery = destinationPolicy !== 'locked'
      && plan.destination.action === 'group'
      && composer.getIn(['userPostingStyle', 'destinationStatus']) === 'failed'
      && String(composer.getIn(['userPostingStyle', 'destinationAccountId'] || '')) === String(plan.destination.accountId || '');

    const origin = selectionOrigin || (style ? 'manual' : 'none');
    const mode = usageMode || (origin === 'saved_default' || origin === 'automatic' || origin === 'usual' ? 'usual' : 'once');

    dispatch(targetComposerAction({
      type: USER_POSTING_STYLE_COMMIT,
      plan,
      snapshot: style,
      resetSuppressions: true,
      restoreParked: false,
      selectionOrigin: origin,
      usageMode: mode,
      selectionKind: selectionKind || (style ? 'style' : 'none'),
      resolutionScope: resolutionScope || null,
      revalidateUsual,
      evaluatedSurface: surface ? { kind: surface.get('kind'), key: surface.get('key') } : null,
    }, composerId));
    dispatch(scheduleComposerInteractionCheck(composerId));

    if (destinationPolicy !== 'locked' && plan.destination.action === 'group') {
      return dispatch(loadUserPostingStyleDestination(composerId, {
        selectedId: plan.selectedId,
        accountId: plan.destination.accountId,
        force: retryingDiscovery,
      }));
    }

    return Promise.resolve();
  };
}

const manualUsage = composer => {
  const usage = composer.getIn(['userPostingStyle', 'usageMode']) || 'usual';

  return usage === 'once' || usage === 'keep';
};

const blocksAutomaticApply = (composer, { revalidate = false } = {}) => {
  const origin = composer.getIn(['userPostingStyle', 'selectionOrigin']);
  const manual = composer.getIn(['userPostingStyle', 'manualFields']);

  // Typed text, a manual field, or an explicit choice stays. A post-success
  // recheck may replace a previous usual/automatic choice.
  if (composer.getIn(['userPostingStyle', 'styleInputLock']) || composerDraftInProgress(composer) || (manual && manual.size > 0)) {
    return true;
  }

  if (origin === 'manual' || origin === 'none') {
    return true;
  }

  if (!revalidate && (origin === 'automatic' || origin === 'saved_default' || origin === 'usual')) {
    return true;
  }

  return false;
};

const generationsCurrent = (getState, { portable, cacheKey, placeGeneration, globalGeneration, checkGlobal }) => {
  const now = getState();

  if (checkGlobal && (now.getIn(['userPostingContextAssignments', 'global', 'generation']) || 0) !== globalGeneration) {
    return false;
  }

  if (!portable) {
    return true;
  }

  const latest = now.getIn(['userPostingContextAssignments', 'bySurface', cacheKey]);

  return Boolean(latest) && !latest.get('writePending') && (latest.get('generation') || 0) === placeGeneration;
};

// One resolver for a new draft, a post-success restore, and an explicit
// return. A manual once/keep choice is left alone. A draft that already
// considered this place is left alone unless success asked for a recheck.
export function settleUsualSelection(composerId) {
  return (dispatch, getState) => {
    const state = getState();
    const composer = selectComposer(state, composerId);
    const surface = composer && composer.get('surface');
    const portable = Boolean(surface);
    const cacheKey = portable ? surfaceCacheKey(surface) : 'primary';

    if (!composer || isExistingPostEdit(composer) || manualUsage(composer) || composer.get('surfaceMismatch')) {
      return Promise.resolve();
    }

    const revalidate = composer.getIn(['userPostingStyle', 'revalidateUsual']) === true;

    if (!revalidate && composer.getIn(['userPostingStyle', 'defaultsSettledSurface']) === cacheKey) {
      return Promise.resolve();
    }

    if (portable && !portablePostingContextReady(composer)) {
      return Promise.resolve();
    }

    const placeAssignment = portable ? state.getIn(['userPostingContextAssignments', 'bySurface', cacheKey]) : null;

    if (portable && (!placeAssignment || placeAssignment.get('writePending'))) {
      return Promise.resolve();
    }

    const decision = decideUsualSelection({
      portable,
      composer,
      styles: state.getIn(['userPostingStyles', 'styles']),
      placeAssignment,
      globalAssignment: state.getIn(['userPostingContextAssignments', 'global']),
      catalogStatus: state.getIn(['userPostingStyles', 'status']),
    });

    if (decision.phase === 'pending' || decision.phase === 'failed') {
      const kind = composer.getIn(['userPostingStyle', 'selectionKind']);

      if (kind !== decision.phase) {
        dispatch(targetComposerAction({
          type: USER_POSTING_STYLE_RESOLUTION,
          selectionKind: decision.phase,
          resolutionScope: decision.scope || null,
          resolvingUsual: decision.phase === 'pending',
        }, composerId));
      }

      return Promise.resolve();
    }

    const current = selectComposer(getState(), composerId);
    const currentSurface = current && current.get('surface');
    const placeGeneration = placeAssignment ? (placeAssignment.get('generation') || 0) : 0;
    const globalGeneration = state.getIn(['userPostingContextAssignments', 'global', 'generation']) || 0;
    const checkGlobal = !portable || decision.scope === 'global' || decision.scope === 'global_unfit';

    if (!current || isExistingPostEdit(current) || manualUsage(current) || current.get('surfaceMismatch')) {
      return Promise.resolve();
    }

    if (portable && (surfaceCacheKey(currentSurface) !== cacheKey || !portablePostingContextReady(current))) {
      return Promise.resolve();
    }

    if (!generationsCurrent(getState, { portable, cacheKey, placeGeneration, globalGeneration, checkGlobal })) {
      return Promise.resolve();
    }

    const blocked = blocksAutomaticApply(current, { revalidate });

    dispatch(targetComposerAction({
      type: USER_POSTING_STYLE_DEFAULTS_SETTLED,
      surfaceKey: cacheKey,
    }, composerId));

    if (blocked || decision.phase !== 'style' || !decision.style) {
      dispatch(targetComposerAction({
        type: USER_POSTING_STYLE_RESOLUTION,
        selectionKind: blocked ? null : decision.phase,
        resolutionScope: decision.scope || null,
        resolvingUsual: false,
        revalidateUsual: false,
      }, composerId));
      return Promise.resolve();
    }

    const confirmed = selectComposer(getState(), composerId);

    if (!confirmed || confirmed.get('surfaceMismatch') || (portable && surfaceCacheKey(confirmed.get('surface')) !== cacheKey) || manualUsage(confirmed) || blocksAutomaticApply(confirmed, { revalidate })) {
      return Promise.resolve();
    }

    if (!generationsCurrent(getState, { portable, cacheKey, placeGeneration, globalGeneration, checkGlobal })) {
      return Promise.resolve();
    }

    const attemptKey = `${cacheKey}:${decision.origin}:${decision.scope}:${decision.style.get('id')}`;

    if (!revalidate && confirmed.getIn(['userPostingStyle', 'autoAttemptKey']) === attemptKey) {
      return Promise.resolve();
    }

    dispatch(targetComposerAction({
      type: USER_POSTING_STYLE_AUTO_ATTEMPT,
      autoAttemptKey: attemptKey,
    }, composerId));

    return dispatch(commitUserPostingStyle(composerId, decision.style.get('id'), {
      selectionOrigin: decision.origin,
      usageMode: 'usual',
      selectionKind: 'style',
      resolutionScope: decision.scope,
      revalidateUsual: false,
      expectedSurface: portable ? { kind: currentSurface.get('kind'), key: currentSurface.get('key') } : undefined,
    }));
  };
}

export function maybeAutoSelectPortablePostingStyle(composerId) {
  return settleUsualSelection(composerId);
}

export function setPostingStyleUsage(composerId, usageMode) {
  return targetComposerAction({
    type: USER_POSTING_STYLE_USAGE,
    usageMode,
  }, composerId);
}

export function retryUsualResolution(composerId) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);

    if (!composer || manualUsage(composer)) {
      return Promise.resolve();
    }

    dispatch(targetComposerAction({
      type: USER_POSTING_STYLE_RESOLUTION,
      selectionKind: 'pending',
      resolvingUsual: true,
      clearSettled: true,
    }, composerId));

    const surface = composer.get('surface');
    const reads = [
      dispatch(fetchUserPostingStyles({ force: true })),
      dispatch(fetchGlobalUsualStyle({ force: true })),
    ];

    if (surface) {
      reads.push(dispatch(fetchUserPostingContextAssignment({
        kind: surface.get('kind'),
        key: surface.get('key'),
      }, { force: true })));
    }

    return Promise.all(reads);
  };
}

export function readUsualDecision(state, composerId) {
  const composer = selectComposer(state, composerId);

  if (!composer) {
    return null;
  }

  const surface = composer.get('surface');
  const portable = Boolean(surface);
  const cacheKey = portable ? surfaceCacheKey(surface) : null;

  return decideUsualSelection({
    portable,
    composer,
    styles: state.getIn(['userPostingStyles', 'styles']),
    placeAssignment: cacheKey ? state.getIn(['userPostingContextAssignments', 'bySurface', cacheKey]) : null,
    globalAssignment: state.getIn(['userPostingContextAssignments', 'global']),
    catalogStatus: state.getIn(['userPostingStyles', 'status']),
  });
}

// Explicit return. Confirmation cancel never calls this with confirmed=true,
// so the in-progress choice and duration stay as they were.
export function returnToUsualSelection(composerId, { confirmed = false } = {}) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);

    if (!composer || isExistingPostEdit(composer)) {
      return { status: 'ignored' };
    }

    const decision = readUsualDecision(getState(), composerId);

    if (!decision || decision.phase === 'pending' || decision.phase === 'failed') {
      dispatch(retryUsualResolution(composerId));
      return { status: decision ? decision.phase : 'pending' };
    }

    if (decision.phase === 'unavailable') {
      dispatch(targetComposerAction({
        type: USER_POSTING_STYLE_RESOLUTION,
        explicit: true,
        usageMode: 'usual',
        selectionKind: 'unavailable',
        resolutionScope: decision.scope || null,
        resolvingUsual: false,
        revalidateUsual: false,
      }, composerId));
      return { status: 'unavailable' };
    }

    const style = decision.phase === 'style' ? decision.style : null;
    const surface = composer.get('surface');
    const destinationPolicy = surface ? 'locked' : 'change';

    if (destinationPolicy === 'locked' && (composer.get('surfaceMismatch') || (style && !styleMatchesSurface(style, surface)))) {
      return { status: 'blocked' };
    }

    const plan = resolveUserPostingStyle(style, composer, { destinationPolicy });

    if (plan.blocked) {
      return { status: 'blocked' };
    }

    if (plan.needsConfirmation && !confirmed) {
      return { status: 'confirm' };
    }

    const latest = selectComposer(getState(), composerId);

    if (!latest || isExistingPostEdit(latest) || (surface && !surfacesEqual(surface, latest.get('surface')))) {
      return { status: 'blocked' };
    }

    dispatch(commitUserPostingStyle(composerId, style ? style.get('id') : null, {
      selectionOrigin: decision.origin || 'usual',
      usageMode: 'usual',
      selectionKind: style ? 'style' : 'none',
      resolutionScope: decision.scope || null,
      revalidateUsual: false,
      expectedSurface: surface ? { kind: surface.get('kind'), key: surface.get('key') } : undefined,
    }));
    return { status: 'applied' };
  };
}

// Saves the usual style only. The open draft, its values, and its duration stay.
export function saveCurrentStyleAsUsual(composerId) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);

    if (!composer || isExistingPostEdit(composer)) {
      return Promise.resolve();
    }

    const kind = composer.getIn(['userPostingStyle', 'selectionKind']);
    const selectedId = composer.getIn(['userPostingStyle', 'selectedId']);

    if (kind === 'none') {
      return dispatch(saveGlobalUsualStyle(null));
    }

    if (kind === 'style' && selectedId) {
      return dispatch(saveGlobalUsualStyle(selectedId));
    }

    return Promise.resolve();
  };
}

export function retryUserPostingStyleDestination(composerId) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);
    const snapshot = composer && composer.getIn(['userPostingStyle', 'snapshot']);
    const accountId = snapshot && snapshot.getIn(['target', 'accountId']);
    const selectedId = composer && composer.getIn(['userPostingStyle', 'selectedId']);

    if (!composer || destinationLocked(composer) || composer.getIn(['userPostingStyle', 'destinationStatus']) !== 'failed' || !selectedId) {
      return Promise.resolve();
    }

    if (!snapshot || snapshot.getIn(['target', 'kind']) !== 'group' || !accountId) {
      return Promise.resolve();
    }

    dispatch(targetComposerAction({
      type: USER_POSTING_STYLE_DESTINATION_RETRY,
    }, composerId));

    return dispatch(loadUserPostingStyleDestination(composerId, {
      selectedId,
      accountId,
      force: true,
    }));
  };
}

export function resolveUserPostingStyleDestination(composerId) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);

    if (!composer || destinationLocked(composer) || composer.getIn(['userPostingStyle', 'destinationStatus']) !== 'needs_resolve') {
      return Promise.resolve();
    }

    const snapshot = composer.getIn(['userPostingStyle', 'snapshot']);
    const accountId = snapshot && snapshot.getIn(['target', 'accountId']);
    const selectedId = composer.getIn(['userPostingStyle', 'selectedId']);

    if (!snapshot || snapshot.getIn(['target', 'kind']) !== 'group' || !accountId) {
      return Promise.resolve();
    }

    dispatch(destinationResult(composerId, { status: 'pending', selectedId, accountId }));

    return dispatch(loadUserPostingStyleDestination(composerId, { selectedId, accountId }));
  };
}

export function toggleUserPostingStyleHashtag(composerId, origin, normalizedName) {
  return targetComposerAction({
    type: USER_POSTING_STYLE_HASHTAG_TOGGLE,
    origin,
    normalizedName,
  }, composerId);
}
