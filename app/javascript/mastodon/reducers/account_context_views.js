import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

export const ACCOUNT_CONTEXT_VIEW_OPEN = 'ACCOUNT_CONTEXT_VIEW_OPEN';
export const ACCOUNT_CONTEXT_VIEW_SEEK = 'ACCOUNT_CONTEXT_VIEW_SEEK';
export const ACCOUNT_CONTEXT_VIEW_NOTICE = 'ACCOUNT_CONTEXT_VIEW_NOTICE';
export const ACCOUNT_CONTEXT_VIEW_RESTORE = 'ACCOUNT_CONTEXT_VIEW_RESTORE';
export const ACCOUNT_CONTEXT_VIEW_CLOSE = 'ACCOUNT_CONTEXT_VIEW_CLOSE';

const initialState = ImmutableMap({
  order: ImmutableList(),
  sessions: ImmutableMap(),
});

const remember = (order, hostKey) => {
  const without = order.filter(key => key !== hostKey);

  return without.push(hostKey);
};

export default function accountContextViews(state = initialState, action) {
  switch (action.type) {
  case ACCOUNT_CONTEXT_VIEW_OPEN:
    if (typeof action.hostKey !== 'string' || !action.hostKey) {
      return state;
    }

    return state.withMutations(map => {
      map.set('order', remember(map.get('order'), action.hostKey));
      map.setIn(['sessions', action.hostKey], ImmutableMap({
        hostKey: action.hostKey,
        generation: action.generation || 1,
        kind: action.kind,
        accountId: action.accountId,
        statusId: action.statusId,
        reply: !!action.reply,
        reblog: !!action.reblog,
        sourceKey: action.sourceKey || '',
        phase: 'seeking',
        notice: null,
        seekSessionId: null,
        scrollRevision: null,
        previousItems: null,
        previousWindow: null,
      }));
    });
  case ACCOUNT_CONTEXT_VIEW_SEEK: {
    const current = state.getIn(['sessions', action.hostKey]);

    if (!current || current.get('generation') !== action.generation || current.get('sourceKey') !== action.sourceKey) {
      return state;
    }

    if (current.get('seekSessionId') && action.seekSessionId !== current.get('seekSessionId')) {
      return state;
    }

    const previous = action.previous || {};

    return state.setIn(['sessions', action.hostKey], current.merge({
      phase: action.outcome === 'resolved' ? 'ready' : 'notice',
      notice: action.outcome === 'resolved' ? null : (action.outcome || 'unknown'),
      seekSessionId: action.seekSessionId || null,
      scrollRevision: action.scrollRevision === undefined ? null : action.scrollRevision,
      previousItems: previous.items || null,
      previousWindow: previous.windowState || null,
    }));
  }
  case ACCOUNT_CONTEXT_VIEW_NOTICE: {
    const current = state.getIn(['sessions', action.hostKey]);

    if (!current || current.get('generation') !== action.generation) {
      return state;
    }

    if (action.seekSessionId && current.get('seekSessionId') && current.get('seekSessionId') !== action.seekSessionId) {
      return state;
    }

    return state.setIn(['sessions', action.hostKey], current.merge({
      phase: action.notice ? 'notice' : current.get('phase'),
      notice: action.notice || null,
    }));
  }
  case ACCOUNT_CONTEXT_VIEW_RESTORE: {
    const current = state.getIn(['sessions', action.hostKey]);
    const prior = action.session;

    if (!current || !prior || current.get('generation') !== action.generation) {
      return state;
    }

    return state.setIn(['sessions', action.hostKey], prior.merge({
      generation: action.generation,
      phase: 'notice',
      notice: action.notice || 'unknown',
      seekSessionId: null,
      scrollRevision: null,
    }));
  }
  case ACCOUNT_CONTEXT_VIEW_CLOSE:
    if (!state.getIn(['sessions', action.hostKey])) {
      return state;
    }

    return state.withMutations(map => {
      map.deleteIn(['sessions', action.hostKey]);
      map.set('order', map.get('order').filter(key => key !== action.hostKey));
    });
  default:
    return state;
  }
}

export const accountContextOrder = (state) => state.getIn(['accountContextViews', 'order'], ImmutableList());

export const accountContextSession = (state, hostKey) => state.getIn(['accountContextViews', 'sessions', hostKey], null);
