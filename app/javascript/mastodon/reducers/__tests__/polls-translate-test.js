import { fromJS } from 'immutable';

jest.mock('../../actions/statuses', () => ({
  STATUS_TRANSLATE_SUCCESS: 'STATUS_TRANSLATE_SUCCESS',
  STATUS_TRANSLATE_UNDO: 'STATUS_TRANSLATE_UNDO',
}));

import { normalizePoll } from '../../actions/importer/normalizer';
import reducer from '../polls';

const STATUS_TRANSLATE_SUCCESS = 'STATUS_TRANSLATE_SUCCESS';
const STATUS_TRANSLATE_UNDO = 'STATUS_TRANSLATE_UNDO';

const poll = fromJS({
  id: 'p1',
  emojis: [],
  options: [
    { title: 'Yes' },
    { title: 'No' },
  ],
});

describe('polls translation reducer', () => {
  it('stores translated option titles and removes them on undo', () => {
    const translated = reducer(fromJS({ p1: poll }), {
      type: STATUS_TRANSLATE_SUCCESS,
      translation: {
        poll: {
          id: 'p1',
          options: [
            { title: 'はい' },
            { title: 'いいえ' },
          ],
        },
      },
    });

    expect(translated.getIn(['p1', 'options', 0, 'translation', 'title'])).toBe('はい');
    expect(translated.getIn(['p1', 'options', 0, 'translation', 'titleHtml'])).toContain('はい');
    expect(translated.getIn(['p1', 'options', 1, 'translation', 'title'])).toBe('いいえ');

    const undone = reducer(translated, {
      type: STATUS_TRANSLATE_UNDO,
      pollId: 'p1',
    });

    expect(undone.getIn(['p1', 'options', 0, 'translation'])).toBeUndefined();
    expect(undone.getIn(['p1', 'options', 1, 'translation'])).toBeUndefined();
    expect(undone.getIn(['p1', 'options', 0, 'title'])).toBe('Yes');
  });

  it('keeps option translations when only the status display mode changes', () => {
    const translated = reducer(fromJS({ p1: poll }), {
      type: STATUS_TRANSLATE_SUCCESS,
      translation: {
        poll: {
          id: 'p1',
          options: [
            { title: 'はい' },
            { title: 'いいえ' },
          ],
        },
      },
    });

    const next = reducer(translated, {
      type: 'STATUS_TRANSLATE_SET_MODE',
      id: 's1',
      mode: 'original',
    });

    expect(next.getIn(['p1', 'options', 0, 'translation', 'title'])).toBe('はい');
    expect(next.getIn(['p1', 'options', 1, 'translation', 'title'])).toBe('いいえ');
    expect(next.getIn(['p1', 'options', 0, 'title'])).toBe('Yes');
  });
});

describe('normalizePoll translation retention', () => {
  const previous = fromJS(normalizePoll({
    id: 'p1',
    emojis: [],
    options: [{ title: 'Yes' }, { title: 'No' }],
    own_votes: [],
  })).setIn(['options', 0, 'translation'], fromJS({ title: 'はい', titleHtml: 'はい' }));

  it('keeps a translation when the option title is unchanged', () => {
    const next = normalizePoll({
      id: 'p1',
      emojis: [],
      options: [{ title: 'Yes' }, { title: 'No' }],
      own_votes: [],
    }, previous);

    expect(next.options[0].translation.get('title')).toBe('はい');
    expect(next.options[1].translation).toBeUndefined();
  });

  it('drops a translation when the option title changes', () => {
    const next = normalizePoll({
      id: 'p1',
      emojis: [],
      options: [{ title: 'Yeah' }, { title: 'No' }],
      own_votes: [],
    }, previous);

    expect(next.options[0].translation).toBeUndefined();
    expect(next.options[0].title).toBe('Yeah');
  });
});
