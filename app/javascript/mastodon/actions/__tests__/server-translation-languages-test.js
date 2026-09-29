jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('../../initial_state', () => ({
  __esModule: true,
  get me() {
    return global.__fedibirdTranslationViewerId;
  },
}));

import api from '../../api';
import { fetchServerTranslationLanguages, SERVER_TRANSLATION_LANGUAGES_FETCH_SUCCESS } from '../server';

const dispatchThunk = async (thunk, state = {}) => {
  const actions = [];
  const dispatch = action => {
    actions.push(action);
    return action;
  };

  await thunk(dispatch, () => state);
  return actions;
};

describe('fetchServerTranslationLanguages', () => {
  beforeEach(() => {
    global.__fedibirdTranslationViewerId = undefined;
    api.mockReset();
    api.mockReturnValue({
      get: jest.fn().mockResolvedValue({ data: { und: ['ja'] } }),
    });
  });

  it('loads the viewer endpoint for a signed-in session', async () => {
    global.__fedibirdTranslationViewerId = '42';

    const actions = await dispatchThunk(fetchServerTranslationLanguages());

    expect(api).toHaveBeenCalled();
    expect(api.mock.results[0].value.get).toHaveBeenCalledWith('/api/v1/fedibird/translation_languages');
    expect(actions).toContainEqual({
      type: SERVER_TRANSLATION_LANGUAGES_FETCH_SUCCESS,
      translationLanguages: { und: ['ja'] },
    });
  });

  it('loads the instance endpoint when no session is present', async () => {
    const actions = await dispatchThunk(fetchServerTranslationLanguages());

    expect(api.mock.results[0].value.get).toHaveBeenCalledWith('/api/v1/instance/translation_languages');
    expect(actions.map(action => action.type)).toContain(SERVER_TRANSLATION_LANGUAGES_FETCH_SUCCESS);
  });
});
