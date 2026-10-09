import { Map as ImmutableMap } from 'immutable';
import {
  USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_FAIL,
  USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_REQUEST,
  USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS,
  USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_FAIL,
  USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_REQUEST,
  USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_SUCCESS,
} from '../actions/user_posting_context_assignments';

const initialState = ImmutableMap({
  bySurface: ImmutableMap(),
});

const blankEntry = () => ImmutableMap({
  status: 'idle',
  assignmentStatus: null,
  styleId: null,
  revision: null,
  generation: 0,
  failure: null,
  surface: null,
});

const readEntry = (state, key) => state.getIn(['bySurface', key]) || blankEntry();

const rememberSurface = (entry, surface) => entry.set('surface', surface ? ImmutableMap({
  kind: surface.kind,
  key: String(surface.key),
}) : entry.get('surface'));

const applyLoaded = (entry, action) => rememberSurface(entry, action.assignment.surface).merge({
  status: 'ready',
  assignmentStatus: action.assignment.assignmentStatus,
  styleId: action.assignment.styleId,
  revision: action.assignment.revision,
  failure: null,
});

export default function userPostingContextAssignments(state = initialState, action) {
  switch (action.type) {
  case USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_REQUEST:
  case USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_REQUEST: {
    const current = readEntry(state, action.surfaceKey);

    if (action.generation < current.get('generation')) {
      return state;
    }

    return state.setIn(['bySurface', action.surfaceKey], rememberSurface(current, action.surface).merge({
      status: action.type === USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_REQUEST ? 'saving' : 'loading',
      generation: action.generation,
      failure: null,
    }));
  }
  case USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS:
  case USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_SUCCESS: {
    const current = readEntry(state, action.surfaceKey);

    if (current.get('generation') !== action.generation || !action.assignment) {
      return state;
    }

    return state.setIn(['bySurface', action.surfaceKey], applyLoaded(current, action));
  }
  case USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_FAIL:
  case USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_FAIL: {
    const current = readEntry(state, action.surfaceKey);

    if (current.get('generation') !== action.generation) {
      return state;
    }

    const saveFailed = action.type === USER_POSTING_CONTEXT_ASSIGNMENT_SAVE_FAIL;

    return state.setIn(['bySurface', action.surfaceKey], current.merge({
      status: saveFailed && current.get('assignmentStatus') ? 'ready' : 'failed',
      failure: saveFailed ? 'save' : 'fetch',
    }));
  }
  default:
    return state;
  }
}
