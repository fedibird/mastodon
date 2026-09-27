import { Map as ImmutableMap, fromJS } from 'immutable';

import {
  SERVER_TRANSLATION_LANGUAGES_FETCH_REQUEST,
  SERVER_TRANSLATION_LANGUAGES_FETCH_SUCCESS,
  SERVER_TRANSLATION_LANGUAGES_FETCH_FAIL,
} from '../actions/server';

const initialState = ImmutableMap({
  translationLanguages: ImmutableMap({
    isLoading: false,
  }),
});

export default function server(state = initialState, action) {
  switch (action.type) {
  case SERVER_TRANSLATION_LANGUAGES_FETCH_REQUEST:
    return state.setIn(['translationLanguages', 'isLoading'], true);
  case SERVER_TRANSLATION_LANGUAGES_FETCH_SUCCESS:
    return state.setIn(['translationLanguages', 'items'], fromJS(action.translationLanguages)).setIn(['translationLanguages', 'isLoading'], false);
  case SERVER_TRANSLATION_LANGUAGES_FETCH_FAIL:
    return state.setIn(['translationLanguages', 'isLoading'], false);
  default:
    return state;
  }
}
