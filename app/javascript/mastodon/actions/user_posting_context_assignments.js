import api from '../api';
import { assignmentSurface, placeDefaultWriteSurface, surfaceCacheKey, surfacesEqual } from '../posting_context/surface';
import { selectComposer } from '../selectors/composer';

export const USER_POSTING_CONTEXT_ASSIGNMENTS_INVALIDATE = 'USER_POSTING_CONTEXT_ASSIGNMENTS_INVALIDATE';
export const USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_REQUEST = 'USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_REQUEST';
export const USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS = 'USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS';
export const USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_FAIL = 'USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_FAIL';
export const USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_REQUEST = 'USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_REQUEST';
export const USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_SUCCESS = 'USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_SUCCESS';
export const USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_FAIL = 'USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_FAIL';

export const USER_POSTING_CONTEXT_ASSIGNMENT_CONSUMER_REGISTER = 'USER_POSTING_CONTEXT_ASSIGNMENT_CONSUMER_REGISTER';
export const USER_POSTING_CONTEXT_ASSIGNMENT_CONSUMER_UNREGISTER = 'USER_POSTING_CONTEXT_ASSIGNMENT_CONSUMER_UNREGISTER';
export const USER_POSTING_CONTEXT_ASSIGNMENT_WRITE_FINISH = 'USER_POSTING_CONTEXT_ASSIGNMENT_WRITE_FINISH';

export const registerAssignmentConsumer = (consumerId, surface) => ({
  type: USER_POSTING_CONTEXT_ASSIGNMENT_CONSUMER_REGISTER, consumerId, surface: assignmentSurface(surface),
});
export const unregisterAssignmentConsumer = consumerId => ({ type: USER_POSTING_CONTEXT_ASSIGNMENT_CONSUMER_UNREGISTER, consumerId });

const PATH = '/api/v1/fedibird/user_posting_context_assignments';
const STATUSES = ['unset', 'none', 'style', 'unavailable'];

const entryGeneration = (state, key) => {
  const entry = state.getIn(['userPostingContextAssignments', 'bySurface', key]);

  return (entry && entry.get('generation')) || 0;
};

export function normalizeAssignmentPayload(data) {
  const surface = assignmentSurface(data && data.surface);

  if (!surface || !STATUSES.includes(data.status)) {
    return null;
  }

  const styleId = data.style_id === null || data.style_id === undefined || data.style_id === '' ? null : String(data.style_id);

  return {
    surface,
    assignmentStatus: data.status,
    styleId: data.status === 'style' || data.status === 'unavailable' ? styleId : null,
    revision: data.revision === null || data.revision === undefined ? null : Number(data.revision),
  };
}

const responseMatchesRequest = (assignment, requested) => (
  Boolean(assignment) && surfacesEqual(assignment.surface, requested)
);

export function fetchUserPostingContextAssignment(surface, { force = false } = {}) {
  return (dispatch, getState) => {
    const requested = assignmentSurface(surface);
    const key = surfaceCacheKey(requested);

    if (!key) {
      return Promise.resolve();
    }

    const status = getState().getIn(['userPostingContextAssignments', 'bySurface', key, 'status']);

    // A failed read stays failed until the user retries. Repeating the
    // controller update must not issue the same GET again.
    if (!force && (status === 'loading' || status === 'ready' || status === 'saving' || status === 'failed')) {
      return Promise.resolve();
    }

    const generation = entryGeneration(getState(), key) + 1;

    dispatch({
      type: USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_REQUEST,
      surfaceKey: key,
      surface: requested,
      generation,
      skipLoading: true,
    });

    return api(getState)
      .get(PATH, { params: { surface_kind: requested.kind, surface_key: requested.key } })
      .then(({ data }) => {
        const assignment = normalizeAssignmentPayload(data);

        if (!responseMatchesRequest(assignment, requested)) {
          dispatch({
            type: USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_FAIL,
            surfaceKey: key,
            generation,
            skipLoading: true,
            skipAlert: true,
          });
          return;
        }

        dispatch({
          type: USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS,
          surfaceKey: key,
          surface: requested,
          assignment,
          generation,
          skipLoading: true,
        });
      })
      .catch(error => {
        dispatch({
          type: USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_FAIL,
          surfaceKey: key,
          generation,
          error,
          skipLoading: true,
          skipAlert: true,
        });
      });
  };
}

// Invalidate every cached place, but fetch only mounted consumers. Closed places
// stay idle and are read lazily when their Controller next mounts.
export function refreshUserPostingContextAssignments() {
  return (dispatch, getState) => {
    dispatch({ type: USER_POSTING_CONTEXT_ASSIGNMENTS_INVALIDATE });
    const consumers = getState().getIn(['userPostingContextAssignments', 'mountedSurfaces']);
    const surfaces = new Map();
    consumers?.forEach(surface => surfaces.set(surfaceCacheKey(surface), surface.toJS()));
    // A Controller may already have reacted to idle and started this read.
    return Promise.all(Array.from(surfaces.values(), surface => dispatch(fetchUserPostingContextAssignment(surface))));
  };
}

const writeAssignment = (surface, request) => (dispatch, getState) => {
  const requested = assignmentSurface(surface);
  const key = surfaceCacheKey(requested);

  if (!key) {
    return Promise.resolve();
  }

  if (getState().getIn(['userPostingContextAssignments', 'bySurface', key, 'writePending'])) {
    return Promise.resolve();
  }

  const refreshEpoch = getState().getIn(['userPostingContextAssignments', 'refreshEpoch'], 0);
  const generation = entryGeneration(getState(), key) + 1;

  dispatch({
    type: USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_REQUEST,
    surfaceKey: key,
    surface: requested,
    generation,
    skipLoading: true,
  });

  return request(api(getState), requested)
    .then(({ data }) => {
      const assignment = normalizeAssignmentPayload(data);

      if (!responseMatchesRequest(assignment, requested)) {
        dispatch({
          type: USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_FAIL,
          surfaceKey: key,
          generation,
          skipLoading: true,
          skipAlert: true,
        });
        return;
      }

      dispatch({
        type: USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_SUCCESS,
        surfaceKey: key,
        surface: requested,
        assignment,
        generation,
        skipLoading: true,
      });
    })
    .catch(error => {
      dispatch({
        type: USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_FAIL,
        surfaceKey: key,
        generation,
        error,
        skipLoading: true,
        skipAlert: true,
      });
    }).finally(() => {
      // Keep the write lock across invalidation/GET readiness, including the
      // gap before a post-write read starts. Only this write's finally unlocks it.
      const superseded = entryGeneration(getState(), key) !== generation
        || getState().getIn(['userPostingContextAssignments', 'refreshEpoch'], 0) !== refreshEpoch;
      const reconciliation = superseded ? dispatch(fetchUserPostingContextAssignment(requested, { force: true })) : undefined;
      dispatch({ type: USER_POSTING_CONTEXT_ASSIGNMENT_WRITE_FINISH, surfaceKey: key, generation });
      return reconciliation;
    });
};

export function saveUserPostingContextAssignment(surface, styleId) {
  return writeAssignment(surface, (client, requested) => client.put(PATH, {
    surface_kind: requested.kind,
    surface_key: requested.key,
    style_id: styleId,
  }));
}

export function resetUserPostingContextAssignment(surface) {
  return writeAssignment(surface, (client, requested) => client.delete(PATH, {
    params: {
      surface_kind: requested.kind,
      surface_key: requested.key,
    },
  }));
}

const guardedSurface = (getState, composerId) => placeDefaultWriteSurface(selectComposer(getState(), composerId));

export function saveGuardedPlaceDefault(composerId, styleId) {
  return (dispatch, getState) => {
    const surface = guardedSurface(getState, composerId);

    if (!surface) {
      return Promise.resolve();
    }

    return dispatch(saveUserPostingContextAssignment(surface, styleId));
  };
}

export function resetGuardedPlaceDefault(composerId) {
  return (dispatch, getState) => {
    const surface = guardedSurface(getState, composerId);

    if (!surface) {
      return Promise.resolve();
    }

    return dispatch(resetUserPostingContextAssignment(surface));
  };
}
