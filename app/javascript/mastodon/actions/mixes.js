import { List as ImmutableList, fromJS } from 'immutable';
import api from '../api';
import { isMixEnabled } from '../mix/availability';
import { prepareMix } from '../mix/definition';
import { saveSettings } from './settings';

export const MIXES_REPLACE = 'MIXES_REPLACE';

const mixesOf = (getState) => getState().getIn(['settings', 'mixes'], ImmutableList());

const unavailable = { ok: false, errors: ['unavailable'] };

const commit = (dispatch, mixes) => {
  dispatch({
    type: MIXES_REPLACE,
    mixes,
  });
  dispatch(saveSettings());
};

export function createMix(draft) {
  return (dispatch, getState) => {
    if (!isMixEnabled()) {
      return unavailable;
    }

    const prepared = prepareMix(draft);

    if (!prepared.ok) {
      return prepared;
    }

    commit(dispatch, mixesOf(getState).push(fromJS(prepared.mix)));
    return prepared;
  };
}

export function updateMix(id, draft) {
  return (dispatch, getState) => {
    if (!isMixEnabled()) {
      return unavailable;
    }

    const prepared = prepareMix({ ...draft, id, version: draft && draft.version });

    if (!prepared.ok) {
      return prepared;
    }

    const mixes = mixesOf(getState);
    const index = mixes.findIndex(mix => mix.get('id') === String(id));
    const next = index === -1 ? mixes.push(fromJS(prepared.mix)) : mixes.set(index, fromJS(prepared.mix));

    commit(dispatch, next);
    return prepared;
  };
}

export function deleteMix(id) {
  return (dispatch, getState) => {
    if (!isMixEnabled()) {
      return unavailable;
    }

    commit(dispatch, mixesOf(getState).filter(mix => mix.get('id') !== String(id)));
    return { ok: true };
  };
}

const accountOption = (type, account) => ({
  type,
  id: String(account.id),
  title: account.acct || account.username || String(account.id),
});

// Reuses the list editor account search and the hashtag column search.
// Results stay in the editor and are not written into mix settings.
export function searchMixSources(type, query) {
  return (dispatch, getState) => {
    const q = String(query || '').trim();

    if (!isMixEnabled() || !q) {
      return Promise.resolve([]);
    }

    if (type === 'hashtag') {
      return api(getState).get('/api/v2/search', {
        params: {
          q,
          type: 'hashtags',
          resolve: false,
          limit: 8,
        },
      }).then(({ data }) => (data.hashtags || []).map(tag => ({
        type: 'hashtag',
        id: tag.name,
        title: `#${tag.name}`,
      })));
    }

    if (type === 'account' || type === 'group') {
      return api(getState).get('/api/v1/accounts/search', {
        params: {
          q,
          resolve: false,
          limit: 8,
        },
      }).then(({ data }) => (data || [])
        .filter(account => (type === 'group' ? account.group === true : account.group !== true))
        .map(account => accountOption(type, account)));
    }

    return Promise.resolve([]);
  };
}
