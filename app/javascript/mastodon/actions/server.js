import api from '../api';

export const SERVER_TRANSLATION_LANGUAGES_FETCH_REQUEST = 'SERVER_TRANSLATION_LANGUAGES_FETCH_REQUEST';
export const SERVER_TRANSLATION_LANGUAGES_FETCH_SUCCESS = 'SERVER_TRANSLATION_LANGUAGES_FETCH_SUCCESS';
export const SERVER_TRANSLATION_LANGUAGES_FETCH_FAIL    = 'SERVER_TRANSLATION_LANGUAGES_FETCH_FAIL';

export const fetchServerTranslationLanguages = () => (dispatch, getState) => {
  dispatch(fetchServerTranslationLanguagesRequest());

  api(getState)
    .get('/api/v1/instance/translation_languages').then(({ data }) => {
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
