import api from '../api';
import * as initialState from '../initial_state';

export const SERVER_TRANSLATION_LANGUAGES_FETCH_REQUEST = 'SERVER_TRANSLATION_LANGUAGES_FETCH_REQUEST';
export const SERVER_TRANSLATION_LANGUAGES_FETCH_SUCCESS = 'SERVER_TRANSLATION_LANGUAGES_FETCH_SUCCESS';
export const SERVER_TRANSLATION_LANGUAGES_FETCH_FAIL    = 'SERVER_TRANSLATION_LANGUAGES_FETCH_FAIL';

// Logged-in sessions read the viewer endpoint so a personal DeepL credential
// can change the language map. Logged-out sessions stay on the instance API.
export const fetchServerTranslationLanguages = () => (dispatch, getState) => {
  dispatch(fetchServerTranslationLanguagesRequest());

  const path = initialState.me
    ? '/api/v1/fedibird/translation_languages'
    : '/api/v1/instance/translation_languages';

  api(getState)
    .get(path).then(({ data }) => {
      dispatch(fetchServerTranslationLanguagesSuccess(data));
    }).catch(err => dispatch(fetchServerTranslationLanguagesFail(err)));
};

const fetchServerTranslationLanguagesRequest = () => ({
  type: SERVER_TRANSLATION_LANGUAGES_FETCH_REQUEST,
});

const fetchServerTranslationLanguagesSuccess = translationLanguages => ({
  type: SERVER_TRANSLATION_LANGUAGES_FETCH_SUCCESS,
  translationLanguages,
});

const fetchServerTranslationLanguagesFail = error => ({
  type: SERVER_TRANSLATION_LANGUAGES_FETCH_FAIL,
  error,
});
