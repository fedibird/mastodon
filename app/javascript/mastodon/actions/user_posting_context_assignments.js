import api from '../api';
import { assignmentSurface, surfaceCacheKey, surfacesEqual } from '../posting_context/surface';

export const USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_REQUEST = 'USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_REQUEST';
export const USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS = 'USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS';
export const USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_FAIL = 'USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_FAIL';
export const USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_REQUEST = 'USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_REQUEST';
export const USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_SUCCESS = 'USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_SUCCESS';
export const USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_FAIL = 'USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_FAIL';

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

    if (!force && (status === 'loading' || status === 'ready' || status === 'saving')) {
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

const writeAssignment = (surface, request) => (dispatch, getState) => {
  const requested = assignmentSurface(surface);
  const key = surfaceCacheKey(requested);

  if (!key) {
    return Promise.resolve();
  }

  if (getState().getIn(['userPostingContextAssignments', 'bySurface', key, 'status']) === 'saving') {
    return Promise.resolve();
  }

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
