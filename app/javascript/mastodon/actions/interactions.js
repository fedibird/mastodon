import api, { getLinks } from '../api';
import { importFetchedAccounts, importFetchedStatus, importFetchedStatuses } from './importer';
import { fetchRelationshipsSuccess, fetchRelationships, fetchRelationshipsFromStatuses } from './accounts';
import { me } from '../initial_state';
import { showAlert, showAlertForError } from './alerts';
import { reactionNameHidden } from '../features/emoji/emoji_mute_projection';
import { currentEmojiMutes, emojiReactionEventsAccepted } from '../features/emoji/emoji_mute_store';
import { emojiReactionsForStatus, emojiReactionAccountIds } from '../utils/emoji_reactions';
import { followReboostOperation } from '../features/reboost/follow_operation';
import uuid from '../uuid';

export const REBOOST_OPERATION = 'REBOOST_OPERATION';

export const REBLOG_REQUEST = 'REBLOG_REQUEST';
export const REBLOG_SUCCESS = 'REBLOG_SUCCESS';
export const REBLOG_FAIL    = 'REBLOG_FAIL';

export const FAVOURITE_REQUEST = 'FAVOURITE_REQUEST';
export const FAVOURITE_SUCCESS = 'FAVOURITE_SUCCESS';
export const FAVOURITE_FAIL    = 'FAVOURITE_FAIL';

export const UNREBLOG_REQUEST = 'UNREBLOG_REQUEST';
export const UNREBLOG_SUCCESS = 'UNREBLOG_SUCCESS';
export const UNREBLOG_FAIL    = 'UNREBLOG_FAIL';

export const UNFAVOURITE_REQUEST = 'UNFAVOURITE_REQUEST';
export const UNFAVOURITE_SUCCESS = 'UNFAVOURITE_SUCCESS';
export const UNFAVOURITE_FAIL    = 'UNFAVOURITE_FAIL';

export const REBLOGS_FETCH_REQUEST = 'REBLOGS_FETCH_REQUEST';
export const REBLOGS_FETCH_SUCCESS = 'REBLOGS_FETCH_SUCCESS';
export const REBLOGS_FETCH_FAIL    = 'REBLOGS_FETCH_FAIL';

export const REBLOGS_EXPAND_REQUEST = 'REBLOGS_EXPAND_REQUEST';
export const REBLOGS_EXPAND_SUCCESS = 'REBLOGS_EXPAND_SUCCESS';
export const REBLOGS_EXPAND_FAIL    = 'REBLOGS_EXPAND_FAIL';

export const FAVOURITES_FETCH_REQUEST = 'FAVOURITES_FETCH_REQUEST';
export const FAVOURITES_FETCH_SUCCESS = 'FAVOURITES_FETCH_SUCCESS';
export const FAVOURITES_FETCH_FAIL    = 'FAVOURITES_FETCH_FAIL';

export const FAVOURITES_EXPAND_REQUEST = 'FAVOURITES_EXPAND_REQUEST';
export const FAVOURITES_EXPAND_SUCCESS = 'FAVOURITES_EXPAND_SUCCESS';
export const FAVOURITES_EXPAND_FAIL    = 'FAVOURITES_EXPAND_FAIL';

export const EMOJI_REACTIONS_FETCH_REQUEST = 'EMOJI_REACTIONS_FETCH_REQUEST';
export const EMOJI_REACTIONS_FETCH_SUCCESS = 'EMOJI_REACTIONS_FETCH_SUCCESS';
export const EMOJI_REACTIONS_FETCH_FAIL    = 'EMOJI_REACTIONS_FETCH_FAIL';

export const EMOJI_REACTIONS_EXPAND_REQUEST = 'EMOJI_REACTIONS_EXPAND_REQUEST';
export const EMOJI_REACTIONS_EXPAND_SUCCESS = 'EMOJI_REACTIONS_EXPAND_SUCCESS';
export const EMOJI_REACTIONS_EXPAND_FAIL    = 'EMOJI_REACTIONS_EXPAND_FAIL';

export const REFERRED_BY_STATUSES_FETCH_REQUEST = 'REFERRED_BY_STATUSES_FETCH_REQUEST';
export const REFERRED_BY_STATUSES_FETCH_SUCCESS = 'REFERRED_BY_STATUSES_FETCH_SUCCESS';
export const REFERRED_BY_STATUSES_FETCH_FAIL    = 'REFERRED_BY_STATUSES_FETCH_FAIL';

export const REFERRED_BY_STATUSES_EXPAND_REQUEST = 'REFERRED_BY_STATUSES_EXPAND_REQUEST';
export const REFERRED_BY_STATUSES_EXPAND_SUCCESS = 'REFERRED_BY_STATUSES_EXPAND_SUCCESS';
export const REFERRED_BY_STATUSES_EXPAND_FAIL    = 'REFERRED_BY_STATUSES_EXPAND_FAIL';

export const MENTIONS_FETCH_REQUEST = 'MENTIONS_FETCH_REQUEST';
export const MENTIONS_FETCH_SUCCESS = 'MENTIONS_FETCH_SUCCESS';
export const MENTIONS_FETCH_FAIL    = 'MENTIONS_FETCH_FAIL';

export const MENTIONS_EXPAND_REQUEST = 'MENTIONS_EXPAND_REQUEST';
export const MENTIONS_EXPAND_SUCCESS = 'MENTIONS_EXPAND_SUCCESS';
export const MENTIONS_EXPAND_FAIL    = 'MENTIONS_EXPAND_FAIL';

export const PIN_REQUEST = 'PIN_REQUEST';
export const PIN_SUCCESS = 'PIN_SUCCESS';
export const PIN_FAIL    = 'PIN_FAIL';

export const UNPIN_REQUEST = 'UNPIN_REQUEST';
export const UNPIN_SUCCESS = 'UNPIN_SUCCESS';
export const UNPIN_FAIL    = 'UNPIN_FAIL';

export const BOOKMARK_REQUEST = 'BOOKMARK_REQUEST';
export const BOOKMARK_SUCCESS = 'BOOKMARKED_SUCCESS';
export const BOOKMARK_FAIL    = 'BOOKMARKED_FAIL';

export const UNBOOKMARK_REQUEST = 'UNBOOKMARKED_REQUEST';
export const UNBOOKMARK_SUCCESS = 'UNBOOKMARKED_SUCCESS';
export const UNBOOKMARK_FAIL    = 'UNBOOKMARKED_FAIL';

export const EMOJI_REACTION_REQUEST = 'EMOJI_REACTION_REQUEST';
export const EMOJI_REACTION_SUCCESS = 'EMOJI_REACTION_SUCCESS';
export const EMOJI_REACTION_FAIL    = 'EMOJI_REACTION_FAIL';

export const UN_EMOJI_REACTION_REQUEST = 'UN_EMOJI_REACTION_REQUEST';
export const UN_EMOJI_REACTION_SUCCESS = 'UN_EMOJI_REACTION_SUCCESS';
export const UN_EMOJI_REACTION_FAIL    = 'UN_EMOJI_REACTION_FAIL';

export const EMOJI_REACTION_UPDATE = 'EMOJI_REACTION_UPDATE';

export function reblog(status, visibility) {
  return function (dispatch, getState) {
    dispatch(reblogRequest(status));

    return api(getState).post(`/api/v1/statuses/${status.get('id')}/reblog`, { visibility }).then(function (response) {
      if (response.status === 202) {
        return acceptReboostResponse(dispatch, getState, status, response);
      }

      // The reblog API method returns a new status wrapped around the original. In this case we are only
      // interested in how the original is modified, hence passing it skipping the wrapper
      dispatch(importFetchedStatus(response.data.reblog));
      dispatch(reblogSuccess(status));
      return null;
    }).catch(function (error) {
      dispatch(reblogFail(status, error));
    });
  };
};

export function setReboostOperation(statusId, operation) {
  return {
    type: REBOOST_OPERATION,
    statusId,
    operation,
  };
}

const reboostMessages = {
  pendingTitle: { id: 'reboost.pending_title', defaultMessage: 'Reboost pending' },
  pending: { id: 'reboost.pending', defaultMessage: 'The previous boost is still being removed. This reboost will continue shortly.' },
  waitTitle: { id: 'reboost.wait_title', defaultMessage: 'Please wait' },
  wait: { id: 'reboost.wait', defaultMessage: 'Wait {seconds} seconds before boosting this post again.' },
  failedTitle: { id: 'reboost.failed_title', defaultMessage: 'Reboost failed' },
  failed: { id: 'reboost.failed', defaultMessage: 'The previous boost could not be replaced.' },
  cancelledTitle: { id: 'reboost.cancelled_title', defaultMessage: 'Reboost cancelled' },
  cancelled: { id: 'reboost.cancelled', defaultMessage: 'The reboost did not finish.' },
  stillPendingTitle: { id: 'reboost.still_pending_title', defaultMessage: 'Reboost still running' },
  stillPending: { id: 'reboost.still_pending', defaultMessage: 'It is still running. Refresh in a moment to see the result.' },
};

const reboostIdempotencyKeys = new Map();

function idempotencyKeyFor(statusId) {
  const existing = reboostIdempotencyKeys.get(statusId);

  if (existing) {
    return existing;
  }

  const key = uuid();
  reboostIdempotencyKeys.set(statusId, key);
  return key;
}

export function reboost(status) {
  return (dispatch, getState) => {
    const statusId = status.get('id');

    if (getState().getIn(['statuses', statusId, 'reboost_operation'])) {
      return Promise.resolve();
    }

    const token = watchReboost(statusId, null);
    dispatch(setReboostOperation(statusId, { state: 'pending' }));

    const idempotencyKey = idempotencyKeyFor(statusId);

    return api(getState).post(`/api/v1/statuses/${statusId}/reblog`, { reboost: true }, {
      headers: { 'Idempotency-Key': idempotencyKey },
    }).then((response) => {
      if (!reboostWatchOwned(statusId, token)) {
        rememberSuspendedResult(statusId, token, { kind: 'post', response });
        return null;
      }

      return settlePostedReboost(dispatch, getState, status, response);
    }).catch((error) => {
      if (!reboostWatchOwned(statusId, token)) {
        rememberSuspendedResult(statusId, token, { kind: 'error', error });
        return null;
      }

      return failPostedReboost(dispatch, status, error);
    });
  };
}

function settlePostedReboost(dispatch, getState, status, response) {
  if (response.status === 202) {
    return acceptReboostResponse(dispatch, getState, status, response);
  }

  const statusId = status.get('id');
  reboostIdempotencyKeys.delete(statusId);
  dispatch(importFetchedStatus(response.data));
  if (response.data.reblog) {
    dispatch(importFetchedStatus(response.data.reblog));
  }
  dispatch(reblogSuccess(status));
  dispatch(setReboostOperation(statusId, null));
  return null;
}

function failPostedReboost(dispatch, status, error) {
  const statusId = status.get('id');
  if (error?.response) {
    reboostIdempotencyKeys.delete(statusId);
  }

  dispatch(setReboostOperation(statusId, null));

  if (error?.response?.status === 429) {
    dispatch(showAlert(
      reboostMessages.waitTitle,
      reboostMessages.wait,
      { seconds: error.response.data?.retry_after },
    ));
    return null;
  }

  dispatch(showAlertForError(error));
  return null;
}

const reboostWatch = new Map();
let reboostWatchSerial = 0;

function watchReboost(statusId, operationId) {
  const current = reboostWatch.get(String(statusId));
  if (current && !current.committed && watchOperationCompatible(current.operationId, operationId)) {
    if (operationId !== null && operationId !== undefined) {
      current.operationId = operationId;
    }
    return current.token;
  }

  const token = ++reboostWatchSerial;
  reboostWatch.set(String(statusId), {
    token,
    operationId: operationId === null || operationId === undefined ? null : operationId,
    committed: false,
  });
  return token;
}

function watchOperationCompatible(currentId, operationId) {
  if (currentId === null || currentId === undefined) {
    return true;
  }

  if (operationId === null || operationId === undefined) {
    return false;
  }

  return String(currentId) === String(operationId);
}

function reboostWatchOpen(statusId, token) {
  const current = reboostWatch.get(String(statusId));
  return !!(current && current.token === token && !current.committed);
}

function commitReboostWatch(statusId, token) {
  const current = reboostWatch.get(String(statusId));
  if (!current || current.token !== token || current.committed) {
    return false;
  }

  current.committed = true;
  return true;
}

function reboostWatchOwned(statusId, token) {
  const current = reboostWatch.get(String(statusId));
  return !!(current && current.token === token);
}

function bumpReboostWatch(statusId, token) {
  const current = reboostWatch.get(String(statusId));
  if (current && current.token === token) {
    current.token = ++reboostWatchSerial;
    current.committed = true;
  }
}

function suspendReboostWatch(statusId) {
  const current = reboostWatch.get(String(statusId));
  if (!current) {
    return null;
  }

  const suspended = { token: current.token, operationId: current.operationId, committed: current.committed, discarded: null };
  current.suspended = suspended;
  current.token = ++reboostWatchSerial;
  current.committed = true;
  return suspended;
}

function rememberSuspendedResult(statusId, token, discarded) {
  const current = reboostWatch.get(String(statusId));
  if (!current?.suspended || current.suspended.token !== token) {
    return;
  }

  current.suspended.discarded = discarded;
}

function restoreReboostWatch(statusId, suspended) {
  if (!suspended) {
    return;
  }

  const current = reboostWatch.get(String(statusId));
  if (!current || String(current.operationId) !== String(suspended.operationId)) {
    return;
  }

  current.token = suspended.token;
  current.committed = false;
  current.suspended = null;
}

function trackedOperationMatches(getState, statusId, operationId) {
  const trackedId = getState().getIn(['statuses', statusId, 'reboost_operation', 'id']);
  return !trackedId || String(trackedId) === String(operationId);
}

function acceptReboostResponse(dispatch, getState, status, response) {
  const operationId = response.data?.operation_id;

  dispatch(setReboostOperation(status.get('id'), { id: operationId, state: response.data?.state || 'pending' }));
  dispatch(showAlert(reboostMessages.pendingTitle, reboostMessages.pending));
  return settleReboost(dispatch, getState, status, operationId);
}

export function checkReboostOperation(status) {
  return (dispatch, getState) => {
    const statusId = status.get('id');
    const operationId = getState().getIn(['statuses', statusId, 'reboost_operation', 'id']);

    if (!operationId) {
      return Promise.resolve();
    }

    const token = watchReboost(statusId, operationId);

    return api(getState).get(`/api/v1/statuses/${statusId}/reboost_operation`, {
      params: { operation_id: operationId },
    }).then((response) => applyReboostResult(dispatch, getState, status, operationId, response.data, token)).catch(() => {
      if (!reboostWatchOpen(statusId, token)) {
        return null;
      }

      dispatch(showAlert(reboostMessages.stillPendingTitle, reboostMessages.stillPending));
      dispatch(setReboostOperation(statusId, { id: operationId, state: 'pending' }));
      return null;
    });
  };
}

function settleReboost(dispatch, getState, status, operationId) {
  const statusId = status.get('id');
  const token = watchReboost(statusId, operationId);

  return followReboostOperation({
    get: (url, config) => api(getState).get(url, config),
    statusId,
    operationId,
    onUpdate: (operation) => {
      if (!reboostWatchOpen(statusId, token) || (operation?.id && String(operation.id) !== String(operationId))) {
        return;
      }

      dispatch(setReboostOperation(statusId, { id: operation.id, state: operation.state }));
    },
  }).then((operation) => applyReboostResult(dispatch, getState, status, operationId, operation, token)).catch(() => {
    if (!reboostWatchOpen(statusId, token)) {
      return null;
    }

    dispatch(showAlert(reboostMessages.stillPendingTitle, reboostMessages.stillPending));
    dispatch(setReboostOperation(statusId, { id: operationId, state: 'pending' }));
    return null;
  });
}

function releaseReboostWatch(dispatch, getState, status, operationId, token) {
  const statusId = status.get('id');
  if (!reboostWatchOwned(statusId, token) || !trackedOperationMatches(getState, statusId, operationId)) {
    return null;
  }

  reboostIdempotencyKeys.delete(statusId);
  dispatch(setReboostOperation(statusId, null));
  bumpReboostWatch(statusId, token);
  return null;
}

function applyReboostResult(dispatch, getState, status, operationId, operation, token) {
  const statusId = status.get('id');
  const trackedId = getState().getIn(['statuses', statusId, 'reboost_operation', 'id']);

  if ((trackedId && String(trackedId) !== String(operationId)) || (operation?.id && String(operation.id) !== String(operationId))) {
    return null;
  }

  if (!reboostWatchOwned(statusId, token)) {
    rememberSuspendedResult(statusId, token, { kind: 'operation', operation });
    return null;
  }

  if (!operation || operation.state === 'pending' || operation.state === 'federating') {
    if (!reboostWatchOpen(statusId, token)) {
      return null;
    }

    dispatch(showAlert(reboostMessages.stillPendingTitle, reboostMessages.stillPending));
    dispatch(setReboostOperation(statusId, { id: operationId, state: operation?.state || 'pending' }));
    return null;
  }

  if (!commitReboostWatch(statusId, token)) {
    return null;
  }

  if (operation.state === 'completed' && operation.new_status_id) {
    return api(getState).get(`/api/v1/statuses/${operation.new_status_id}`).then((response) => {
      if (!reboostWatchOwned(statusId, token) || !trackedOperationMatches(getState, statusId, operationId)) {
        if (!reboostWatchOwned(statusId, token)) {
          rememberSuspendedResult(statusId, token, { kind: 'status', data: response.data });
        }
        return null;
      }

      dispatch(importFetchedStatus(response.data));
      dispatch(reblogSuccess(status));
      return releaseReboostWatch(dispatch, getState, status, operationId, token);
    }).catch((error) => {
      if (!reboostWatchOwned(statusId, token) || !trackedOperationMatches(getState, statusId, operationId)) {
        return null;
      }

      dispatch(showAlertForError(error));
      return releaseReboostWatch(dispatch, getState, status, operationId, token);
    });
  }

  dispatch(showAlert(
    operation.state === 'cancelled' ? reboostMessages.cancelledTitle : reboostMessages.failedTitle,
    operation.state === 'cancelled' ? reboostMessages.cancelled : reboostMessages.failed,
  ));

  return api(getState).get(`/api/v1/statuses/${statusId}`).then((response) => {
    if (reboostWatchOwned(statusId, token) && trackedOperationMatches(getState, statusId, operationId)) {
      dispatch(importFetchedStatus(response.data));
    }
    return null;
  }).catch((error) => {
    if (reboostWatchOwned(statusId, token) && trackedOperationMatches(getState, statusId, operationId)) {
      dispatch(showAlertForError(error));
    }
    return null;
  }).then(() => releaseReboostWatch(dispatch, getState, status, operationId, token));
}

export function unreblog(status) {
  return (dispatch, getState) => {
    const statusId = status.get('id');
    const suspended = suspendReboostWatch(statusId);
    dispatch(unreblogRequest(status));

    return api(getState).post(`/api/v1/statuses/${statusId}/unreblog`).then(response => {
      dispatch(importFetchedStatus(response.data));
      dispatch(unreblogSuccess(status));
      if (!suspended) {
        return null;
      }

      reboostIdempotencyKeys.delete(statusId);
      dispatch(setReboostOperation(statusId, null));
      return null;
    }).catch(error => {
      const discarded = suspended?.discarded;
      restoreReboostWatch(statusId, suspended);
      dispatch(unreblogFail(status, error));
      return replayDiscardedReboost(dispatch, getState, status, discarded, suspended?.token);
    });
  };
};

function replayDiscardedReboost(dispatch, getState, status, discarded, token) {
  if (!discarded || !reboostWatchOwned(status.get('id'), token)) {
    return null;
  }

  if (discarded.kind === 'post') {
    return settlePostedReboost(dispatch, getState, status, discarded.response);
  }

  if (discarded.kind === 'error') {
    return failPostedReboost(dispatch, status, discarded.error);
  }

  if (discarded.kind === 'operation') {
    return applyReboostResult(dispatch, getState, status, discarded.operation?.id, discarded.operation, token);
  }

  dispatch(importFetchedStatus(discarded.data));
  dispatch(reblogSuccess(status));
  reboostIdempotencyKeys.delete(status.get('id'));
  dispatch(setReboostOperation(status.get('id'), null));
  bumpReboostWatch(status.get('id'), token);
  return null;
}

export function reblogRequest(status) {
  return {
    type: REBLOG_REQUEST,
    status: status,
    skipLoading: true,
  };
};

export function reblogSuccess(status) {
  return {
    type: REBLOG_SUCCESS,
    status: status,
    skipLoading: true,
  };
};

export function reblogFail(status, error) {
  return {
    type: REBLOG_FAIL,
    status: status,
    error: error,
    skipLoading: true,
  };
};

export function unreblogRequest(status) {
  return {
    type: UNREBLOG_REQUEST,
    status: status,
    skipLoading: true,
  };
};

export function unreblogSuccess(status) {
  return {
    type: UNREBLOG_SUCCESS,
    status: status,
    skipLoading: true,
  };
};

export function unreblogFail(status, error) {
  return {
    type: UNREBLOG_FAIL,
    status: status,
    error: error,
    skipLoading: true,
  };
};

export function favourite(status) {
  return function (dispatch, getState) {
    dispatch(favouriteRequest(status));

    api(getState).post(`/api/v1/statuses/${status.get('id')}/favourite`).then(function (response) {
      dispatch(importFetchedStatus(response.data));
      dispatch(favouriteSuccess(status));
    }).catch(function (error) {
      dispatch(favouriteFail(status, error));
    });
  };
};

export function unfavourite(status) {
  return (dispatch, getState) => {
    dispatch(unfavouriteRequest(status));

    api(getState).post(`/api/v1/statuses/${status.get('id')}/unfavourite`).then(response => {
      dispatch(importFetchedStatus(response.data));
      dispatch(unfavouriteSuccess(status));
    }).catch(error => {
      dispatch(unfavouriteFail(status, error));
    });
  };
};

export function favouriteRequest(status) {
  return {
    type: FAVOURITE_REQUEST,
    status: status,
    skipLoading: true,
  };
};

export function favouriteSuccess(status) {
  return {
    type: FAVOURITE_SUCCESS,
    status: status,
    skipLoading: true,
  };
};

export function favouriteFail(status, error) {
  return {
    type: FAVOURITE_FAIL,
    status: status,
    error: error,
    skipLoading: true,
  };
};

export function unfavouriteRequest(status) {
  return {
    type: UNFAVOURITE_REQUEST,
    status: status,
    skipLoading: true,
  };
};

export function unfavouriteSuccess(status) {
  return {
    type: UNFAVOURITE_SUCCESS,
    status: status,
    skipLoading: true,
  };
};

export function unfavouriteFail(status, error) {
  return {
    type: UNFAVOURITE_FAIL,
    status: status,
    error: error,
    skipLoading: true,
  };
};

export function bookmark(status) {
  return function (dispatch, getState) {
    dispatch(bookmarkRequest(status));

    api(getState).post(`/api/v1/statuses/${status.get('id')}/bookmark`).then(function (response) {
      dispatch(importFetchedStatus(response.data));
      dispatch(bookmarkSuccess(status, response.data));
    }).catch(function (error) {
      dispatch(bookmarkFail(status, error));
    });
  };
};

export function unbookmark(status) {
  return (dispatch, getState) => {
    dispatch(unbookmarkRequest(status));

    api(getState).post(`/api/v1/statuses/${status.get('id')}/unbookmark`).then(response => {
      dispatch(importFetchedStatus(response.data));
      dispatch(unbookmarkSuccess(status, response.data));
    }).catch(error => {
      dispatch(unbookmarkFail(status, error));
    });
  };
};

export function bookmarkRequest(status) {
  return {
    type: BOOKMARK_REQUEST,
    status: status,
  };
};

export function bookmarkSuccess(status, response) {
  return {
    type: BOOKMARK_SUCCESS,
    status: status,
    response: response,
  };
};

export function bookmarkFail(status, error) {
  return {
    type: BOOKMARK_FAIL,
    status: status,
    error: error,
  };
};

export function unbookmarkRequest(status) {
  return {
    type: UNBOOKMARK_REQUEST,
    status: status,
  };
};

export function unbookmarkSuccess(status, response) {
  return {
    type: UNBOOKMARK_SUCCESS,
    status: status,
    response: response,
  };
};

export function unbookmarkFail(status, error) {
  return {
    type: UNBOOKMARK_FAIL,
    status: status,
    error: error,
  };
};

export function fetchReblogs(id) {
  return (dispatch, getState) => {
    dispatch(fetchReblogsRequest(id));

    api(getState).get(`/api/v1/statuses/${id}/reblogged_by`).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      dispatch(importFetchedAccounts(response.data));
      dispatch(fetchRelationships(response.data.map(accounts => accounts.id)));
      dispatch(fetchReblogsSuccess(id, response.data, next ? next.uri : null));
    }).catch(error => {
      dispatch(fetchReblogsFail(id, error));
    });
  };
};

export function fetchReblogsRequest(id) {
  return {
    type: REBLOGS_FETCH_REQUEST,
    id,
  };
};

export function fetchReblogsSuccess(id, accounts, next) {
  return {
    type: REBLOGS_FETCH_SUCCESS,
    id,
    accounts,
    next,
  };
};

export function fetchReblogsFail(id, error) {
  return {
    type: REBLOGS_FETCH_FAIL,
    id,
    error,
  };
};

export function expandReblogs(id) {
  return (dispatch, getState) => {
    const url = getState().getIn(['user_lists', 'reblogged_by', id, 'next'], null);

    if (url === null || getState().getIn(['user_lists', 'reblogged_by', id, 'isLoading'])) {
      return;
    }

    dispatch(expandReblogsRequest(id));

    api(getState).get(url).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      dispatch(importFetchedAccounts(response.data));
      dispatch(fetchRelationships(response.data.map(accounts => accounts.id)));
      dispatch(expandReblogsSuccess(id, response.data, next ? next.uri : null));
    }).catch(error => {
      dispatch(expandReblogsFail(id, error));
    });
  };
};

export function expandReblogsRequest(id) {
  return {
    type: REBLOGS_EXPAND_REQUEST,
    id,
  };
};

export function expandReblogsSuccess(id, accounts, next) {
  return {
    type: REBLOGS_EXPAND_SUCCESS,
    id,
    accounts,
    next,
  };
};

export function expandReblogsFail(id, error) {
  return {
    type: REBLOGS_EXPAND_FAIL,
    id,
    error,
  };
};

export function fetchFavourites(id) {
  return (dispatch, getState) => {
    dispatch(fetchFavouritesRequest(id));

    api(getState).get(`/api/v1/statuses/${id}/favourited_by`).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      dispatch(importFetchedAccounts(response.data));
      dispatch(fetchRelationships(response.data.map(accounts => accounts.id)));
      dispatch(fetchFavouritesSuccess(id, response.data, next ? next.uri : null));
    }).catch(error => {
      dispatch(fetchFavouritesFail(id, error));
    });
  };
};

export function fetchFavouritesRequest(id) {
  return {
    type: FAVOURITES_FETCH_REQUEST,
    id,
  };
};

export function fetchFavouritesSuccess(id, accounts, next) {
  return {
    type: FAVOURITES_FETCH_SUCCESS,
    id,
    accounts,
    next,
  };
};

export function fetchFavouritesFail(id, error) {
  return {
    type: FAVOURITES_FETCH_FAIL,
    id,
    error,
  };
};

export function expandFavourites(id) {
  return (dispatch, getState) => {
    const url = getState().getIn(['user_lists', 'favourited_by', id, 'next'], null);

    if (url === null || getState().getIn(['user_lists', 'favourited_by', id, 'isLoading'])) {
      return;
    }

    dispatch(expandFavouritesRequest(id));

    api(getState).get(url).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      dispatch(importFetchedAccounts(response.data));
      dispatch(fetchRelationships(response.data.map(accounts => accounts.id)));
      dispatch(expandFavouritesSuccess(id, response.data, next ? next.uri : null));
    }).catch(error => {
      dispatch(expandFavouritesFail(id, error));
    });
  };
};

export function expandFavouritesRequest(id) {
  return {
    type: FAVOURITES_EXPAND_REQUEST,
    id,
  };
};

export function expandFavouritesSuccess(id, accounts, next) {
  return {
    type: FAVOURITES_EXPAND_SUCCESS,
    id,
    accounts,
    next,
  };
};

export function expandFavouritesFail(id, error) {
  return {
    type: FAVOURITES_EXPAND_FAIL,
    id,
    error,
  };
};

export function fetchEmojiReactions(id) {
  return (dispatch, getState) => {
    dispatch(fetchEmojiReactionsRequest(id));

    api(getState).get(`/api/v1/statuses/${id}/emoji_reactioned_by`).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      dispatch(importFetchedAccounts(response.data.map(emojiReaction => emojiReaction.account)));
      dispatch(fetchRelationships(response.data.map(emojiReaction => emojiReaction.account.id)));
      dispatch(fetchEmojiReactionsSuccess(id, response.data, next ? next.uri : null));
    }).catch(error => {
      dispatch(fetchEmojiReactionsFail(id, error));
    });
  };
};

export function fetchEmojiReactionsRequest(id) {
  return {
    type: EMOJI_REACTIONS_FETCH_REQUEST,
    id,
  };
};

export function fetchEmojiReactionsSuccess(id, emojiReactions, next) {
  return {
    type: EMOJI_REACTIONS_FETCH_SUCCESS,
    id,
    emojiReactions,
    next,
  };
};

export function fetchEmojiReactionsFail(id, error) {
  return {
    type: EMOJI_REACTIONS_FETCH_FAIL,
    id,
    error,
  };
};

export function expandEmojiReactions(id) {
  return (dispatch, getState) => {
    const url = getState().getIn(['user_lists', 'emoji_reactioned_by', id, 'next'], null);

    if (url === null || getState().getIn(['user_lists', 'emoji_reactioned_by', id, 'isLoading'])) {
      return;
    }

    dispatch(expandEmojiReactionsRequest(id));

    api(getState).get(url).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      dispatch(importFetchedAccounts(response.data.map(emojiReaction => emojiReaction.account)));
      dispatch(fetchRelationships(response.data.map(emojiReaction => emojiReaction.account.id)));
      dispatch(expandEmojiReactionsSuccess(id, response.data, next ? next.uri : null));
    }).catch(error => {
      dispatch(expandEmojiReactionsFail(id, error));
    });
  };
};

export function expandEmojiReactionsRequest(id) {
  return {
    type: EMOJI_REACTIONS_EXPAND_REQUEST,
    id,
  };
};

export function expandEmojiReactionsSuccess(id, emojiReactions, next) {
  return {
    type: EMOJI_REACTIONS_EXPAND_SUCCESS,
    id,
    emojiReactions,
    next,
  };
};

export function expandEmojiReactionsFail(id, error) {
  return {
    type: EMOJI_REACTIONS_EXPAND_FAIL,
    id,
    error,
  };
};

export function fetchReferredByStatuses(id) {
  return (dispatch, getState) => {
    dispatch(fetchReferredByStatusesRequest(id));

    api(getState).get(`/api/v1/statuses/${id}/referred_by?compact=true`).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      if (response.data) {
        if ('statuses' in response.data && 'accounts' in response.data) {
          const { statuses, referenced_statuses, accounts, relationships } = response.data;
          dispatch(importFetchedAccounts(accounts));
          dispatch(importFetchedStatuses(statuses.concat(referenced_statuses)));
          dispatch(fetchRelationshipsSuccess(relationships));
          dispatch(fetchReferredByStatusesSuccess(id, statuses, next ? next.uri : null));
        } else {
          const statuses = response.data;
          dispatch(importFetchedStatuses(statuses));
          dispatch(fetchRelationshipsFromStatuses(statuses));
          dispatch(fetchReferredByStatusesSuccess(id, statuses, next ? next.uri : null));
        }
      }
    }).catch(error => {
      dispatch(fetchReferredByStatusesFail(id, error));
    });
  };
};

export function fetchReferredByStatusesRequest(id) {
  return {
    type: REFERRED_BY_STATUSES_FETCH_REQUEST,
    id,
  };
};

export function fetchReferredByStatusesSuccess(id, statuses, next) {
  return {
    type: REFERRED_BY_STATUSES_FETCH_SUCCESS,
    id,
    statuses,
    next,
  };
};

export function fetchReferredByStatusesFail(id, error) {
  return {
    type: REFERRED_BY_STATUSES_FETCH_FAIL,
    id,
    error,
  };
};

export function expandReferredByStatuses(id) {
  return (dispatch, getState) => {
    const url = getState().getIn(['user_lists', 'referred_by', id, 'next'], null);

    if (url === null || getState().getIn(['user_lists', 'referred_by', id, 'isLoading'])) {
      return;
    }

    dispatch(expandReferredByStatusesRequest(id));

    api(getState).get(url).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      if (response.data) {
        if ('statuses' in response.data && 'accounts' in response.data) {
          const { statuses, referenced_statuses, accounts, relationships } = response.data;
          dispatch(importFetchedAccounts(accounts));
          dispatch(importFetchedStatuses(statuses.concat(referenced_statuses)));
          dispatch(fetchRelationshipsSuccess(relationships));
          dispatch(expandReferredByStatusesSuccess(id, statuses, next ? next.uri : null));
        } else {
          const statuses = response.data;
          dispatch(importFetchedStatuses(statuses));
          dispatch(fetchRelationshipsFromStatuses(statuses));
          dispatch(expandReferredByStatusesSuccess(id, statuses, next ? next.uri : null));
        }
      }
    }).catch(error => {
      dispatch(expandReferredByStatusesFail(id, error));
    });
  };
};

export function expandReferredByStatusesRequest(id) {
  return {
    type: REFERRED_BY_STATUSES_EXPAND_REQUEST,
    id,
  };
};

export function expandReferredByStatusesSuccess(id, statuses, next) {
  return {
    type: REFERRED_BY_STATUSES_EXPAND_SUCCESS,
    id,
    statuses,
    next,
  };
};

export function expandReferredByStatusesFail(id, error) {
  return {
    type: REFERRED_BY_STATUSES_EXPAND_FAIL,
    id,
    error,
  };
};

export function fetchMentions(id) {
  return (dispatch, getState) => {
    dispatch(fetchMentionsRequest(id));

    api(getState).get(`/api/v1/statuses/${id}/mentioned_by`).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      dispatch(importFetchedAccounts(response.data));
      dispatch(fetchRelationships(response.data.map(accounts => accounts.id)));
      dispatch(fetchMentionsSuccess(id, response.data, next ? next.uri : null));
    }).catch(error => {
      dispatch(fetchMentionsFail(id, error));
    });
  };
};

export function fetchMentionsRequest(id) {
  return {
    type: MENTIONS_FETCH_REQUEST,
    id,
  };
};

export function fetchMentionsSuccess(id, accounts, next) {
  return {
    type: MENTIONS_FETCH_SUCCESS,
    id,
    accounts,
    next,
  };
};

export function fetchMentionsFail(id, error) {
  return {
    type: MENTIONS_FETCH_FAIL,
    id,
    error,
  };
};

export function expandMentions(id) {
  return (dispatch, getState) => {
    const url = getState().getIn(['user_lists', 'emoji_reactioned_by', id, 'next'], null);

    if (url === null || getState().getIn(['user_lists', 'emoji_reactioned_by', id, 'isLoading'])) {
      return;
    }

    dispatch(expandMentionsRequest(id));

    api(getState).get(url).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      dispatch(importFetchedAccounts(response.data));
      dispatch(fetchRelationships(response.data.map(accounts => accounts.id)));
      dispatch(expandMentionsSuccess(id, response.data, next ? next.uri : null));
    }).catch(error => {
      dispatch(expandMentionsFail(id, error));
    });
  };
};

export function expandMentionsRequest(id) {
  return {
    type: MENTIONS_EXPAND_REQUEST,
    id,
  };
};

export function expandMentionsSuccess(id, accounts, next) {
  return {
    type: MENTIONS_EXPAND_SUCCESS,
    id,
    accounts,
    next,
  };
};

export function expandMentionsFail(id, error) {
  return {
    type: MENTIONS_EXPAND_FAIL,
    id,
    error,
  };
};

export function pin(status) {
  return (dispatch, getState) => {
    dispatch(pinRequest(status));

    api(getState).post(`/api/v1/statuses/${status.get('id')}/pin`).then(response => {
      dispatch(importFetchedStatus(response.data));
      dispatch(pinSuccess(status));
    }).catch(error => {
      dispatch(pinFail(status, error));
    });
  };
};

export function pinRequest(status) {
  return {
    type: PIN_REQUEST,
    status,
    skipLoading: true,
  };
};

export function pinSuccess(status) {
  return {
    type: PIN_SUCCESS,
    status,
    skipLoading: true,
  };
};

export function pinFail(status, error) {
  return {
    type: PIN_FAIL,
    status,
    error,
    skipLoading: true,
  };
};

export function unpin (status) {
  return (dispatch, getState) => {
    dispatch(unpinRequest(status));

    api(getState).post(`/api/v1/statuses/${status.get('id')}/unpin`).then(response => {
      dispatch(importFetchedStatus(response.data));
      dispatch(unpinSuccess(status));
    }).catch(error => {
      dispatch(unpinFail(status, error));
    });
  };
};

export function unpinRequest(status) {
  return {
    type: UNPIN_REQUEST,
    status,
    skipLoading: true,
  };
};

export function unpinSuccess(status) {
  return {
    type: UNPIN_SUCCESS,
    status,
    skipLoading: true,
  };
};

export function unpinFail(status, error) {
  return {
    type: UNPIN_FAIL,
    status,
    error,
    skipLoading: true,
  };
};

export function addEmojiReaction(status, name, domain, url, static_url) {
  return function (dispatch, getState) {
    const hidden = !emojiReactionEventsAccepted() || reactionNameHidden(name, domain, currentEmojiMutes());

    if (!hidden) {
      dispatch(emojiReactionRequest(status, name, domain, url, static_url));
    }

    api(getState).put(`/api/v1/statuses/${status.get('id')}/emoji_reactions/${name}${domain ? `@${domain}` : ''}`).then(function (response) {
      dispatch(importFetchedStatus(response.data));
      dispatch(emojiReactionSuccess(status, name, domain, url, static_url));
    }).catch(function (error) {
      if (!hidden) {
        dispatch(emojiReactionFail(status, name, domain, url, static_url, error));
      }
    });
  };
};

export function emojiReactionRequest(status, name, domain, url, static_url) {
  return {
    type: EMOJI_REACTION_REQUEST,
    status: status,
    name: name,
    domain: domain,
    url: url,
    static_url: static_url,
    skipLoading: true,
  };
};

export function emojiReactionSuccess(status, name, domain, url, static_url) {
  return {
    type: EMOJI_REACTION_SUCCESS,
    status: status,
    name: name,
    domain: domain,
    url: url,
    static_url: static_url,
    skipLoading: true,
  };
};

export function emojiReactionFail(status, name, domain, url, static_url, error) {
  return {
    type: EMOJI_REACTION_FAIL,
    status: status,
    name: name,
    domain: domain,
    url: url,
    static_url: static_url,
    error: error,
    skipLoading: true,
  };
};

const findMyEmojiReaction = (status, name) => emojiReactionsForStatus(status).find(
  emojiReaction => emojiReactionAccountIds(emojiReaction).includes(me) && emojiReaction.get('name') === name,
);

export function removeEmojiReaction(status, name) {
  return function (dispatch, getState) {
    const emoji_reaction = findMyEmojiReaction(status, name);

    if (emoji_reaction) {
      const { name, domain, url, static_url } = emoji_reaction.toObject();

      dispatch(unEmojiReactionRequest(status, name, domain, url, static_url));

      api(getState).delete(`/api/v1/statuses/${status.get('id')}/emoji_reactions/${name}${domain ? `@${domain}` : ''}`).then(function (response) {
        dispatch(importFetchedStatus(response.data));
        dispatch(unEmojiReactionSuccess(status, name, domain, url, static_url));
      }).catch(function (error) {
        dispatch(unEmojiReactionFail(status, name, domain, url, static_url, error));
      });
    }
  };
};

export function unEmojiReactionRequest(status, name, domain, url, static_url) {
  return {
    type: UN_EMOJI_REACTION_REQUEST,
    status: status,
    name: name,
    domain: domain,
    url: url,
    static_url: static_url,
    skipLoading: true,
  };
};

export function unEmojiReactionSuccess(status, name, domain, url, static_url) {
  return {
    type: UN_EMOJI_REACTION_SUCCESS,
    status: status,
    name: name,
    domain: domain,
    url: url,
    static_url: static_url,
    skipLoading: true,
  };
};

export function unEmojiReactionFail(status, name, domain, url, static_url, error) {
  return {
    type: UN_EMOJI_REACTION_FAIL,
    status: status,
    name: name,
    domain: domain,
    url: url,
    static_url: static_url,
    error: error,
    skipLoading: true,
  };
};

export const updateEmojiReaction = emoji_reaction => {
  return (dispatch) => {
    if (!emojiReactionEventsAccepted()) {
      return;
    }

    dispatch({
      type: EMOJI_REACTION_UPDATE,
      emojiReaction: emoji_reaction,
      emojiMuteRules: currentEmojiMutes(),
      skipLoading: true,
    });
  };
};
