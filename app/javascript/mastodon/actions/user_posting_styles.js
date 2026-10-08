import { fromJS } from 'immutable';
import api from '../api';
import { applyComposerPostingContext, targetComposerAction } from './composer';
import { fetchPostingContext } from './posting_contexts';
import { isExistingPostEdit } from '../posting_context/materialize';
import { normalizeUserPostingStyle, resolveUserPostingStyle } from '../posting_context/user_style_resolver';
import { selectComposer } from '../selectors/composer';
import { selectPostingContextDiscovery, selectPostingContextForAccount } from '../selectors/posting_contexts';

export const USER_POSTING_STYLES_FETCH_REQUEST = 'USER_POSTING_STYLES_FETCH_REQUEST';
export const USER_POSTING_STYLES_FETCH_SUCCESS = 'USER_POSTING_STYLES_FETCH_SUCCESS';
export const USER_POSTING_STYLES_FETCH_FAIL = 'USER_POSTING_STYLES_FETCH_FAIL';
export const USER_POSTING_STYLE_COMMIT = 'USER_POSTING_STYLE_COMMIT';
export const USER_POSTING_STYLE_DESTINATION = 'USER_POSTING_STYLE_DESTINATION';
export const USER_POSTING_STYLE_HASHTAG_TOGGLE = 'USER_POSTING_STYLE_HASHTAG_TOGGLE';

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

export function fetchUserPostingStyles({ force = false } = {}) {
  return (dispatch, getState) => {
    const status = getState().getIn(['userPostingStyles', 'status']);

    if (status === 'loading' || (!force && (status === 'ready' || status === 'failed'))) {
      return Promise.resolve();
    }

    dispatch({ type: USER_POSTING_STYLES_FETCH_REQUEST, skipLoading: true });

    return api(getState)
      .get('/api/v1/fedibird/user_posting_contexts')
      .then(({ data }) => {
        const styles = (Array.isArray(data) ? data : []).map(style => fromJS(normalizeUserPostingStyle(style)));

        dispatch({
          type: USER_POSTING_STYLES_FETCH_SUCCESS,
          styles,
          skipLoading: true,
        });
      })
      .catch(error => {
        dispatch({
          type: USER_POSTING_STYLES_FETCH_FAIL,
          error,
          skipLoading: true,
          skipAlert: true,
        });
      });
  };
}

export function loadUserPostingStyleDestination(composerId, { selectedId, accountId, force = false }) {
  return (dispatch, getState) => {
    if (!stillWaiting(getState, composerId, selectedId, accountId)) {
      return Promise.resolve();
    }

    return dispatch(fetchPostingContext(accountId, { force })).then(() => {
      if (!stillWaiting(getState, composerId, selectedId, accountId)) {
        return;
      }

      const discovery = selectPostingContextDiscovery(getState(), accountId);

      const status = discovery && discovery.get('status');

      if (status !== 'resolved') {
        dispatch(destinationResult(composerId, {
          status: 'failed',
          failure: status === 'unsupported' || status === 'not_applicable' ? 'unsupported' : 'error',
          selectedId,
          accountId,
        }));
        return;
      }

      const context = selectPostingContextForAccount(getState(), accountId);

      if (!context || !stillWaiting(getState, composerId, selectedId, accountId)) {
        dispatch(destinationResult(composerId, { status: 'failed', failure: 'error', selectedId, accountId }));
        return;
      }

      dispatch(applyComposerPostingContext(composerId, context));

      if (!stillWaiting(getState, composerId, selectedId, accountId)) {
        return;
      }

      dispatch(destinationResult(composerId, { status: 'ready', selectedId, accountId }));
    });
  };
}

export function commitUserPostingStyle(composerId, styleId) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);

    if (!composer || isExistingPostEdit(composer)) {
      return Promise.resolve();
    }

    const style = styleId === null || styleId === undefined ? null : selectStyle(getState(), styleId);

    if (styleId !== null && styleId !== undefined && !style) {
      return Promise.resolve();
    }

    const plan = resolveUserPostingStyle(style, composer);

    if (plan.blocked) {
      return Promise.resolve();
    }

    const retryingDiscovery = plan.destination.action === 'group'
      && composer.getIn(['userPostingStyle', 'destinationStatus']) === 'failed'
      && String(composer.getIn(['userPostingStyle', 'destinationAccountId'] || '')) === String(plan.destination.accountId || '');

    dispatch(targetComposerAction({
      type: USER_POSTING_STYLE_COMMIT,
      plan,
      snapshot: style,
      resetSuppressions: true,
      restoreParked: false,
    }, composerId));

    if (plan.destination.action === 'group') {
      return dispatch(loadUserPostingStyleDestination(composerId, {
        selectedId: plan.selectedId,
        accountId: plan.destination.accountId,
        force: retryingDiscovery,
      }));
    }

    return Promise.resolve();
  };
}

export function resolveUserPostingStyleDestination(composerId) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);

    if (!composer || composer.getIn(['userPostingStyle', 'destinationStatus']) !== 'needs_resolve') {
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
