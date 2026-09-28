import { fromJS } from 'immutable';

jest.mock('../../actions/statuses', () => ({
  STATUS_MUTE_SUCCESS: 'STATUS_MUTE_SUCCESS',
  STATUS_UNMUTE_SUCCESS: 'STATUS_UNMUTE_SUCCESS',
  STATUS_REVEAL: 'STATUS_REVEAL',
  STATUS_HIDE: 'STATUS_HIDE',
  STATUS_COLLAPSE: 'STATUS_COLLAPSE',
  STATUS_TRANSLATE_SUCCESS: 'STATUS_TRANSLATE_SUCCESS',
  STATUS_TRANSLATE_UNDO: 'STATUS_TRANSLATE_UNDO',
  STATUS_TRANSLATE_REQUEST: 'STATUS_TRANSLATE_REQUEST',
  STATUS_TRANSLATE_FAIL: 'STATUS_TRANSLATE_FAIL',
  STATUS_TRANSLATE_SET_MODE: 'STATUS_TRANSLATE_SET_MODE',
  STATUS_TRANSLATION_ASSUMPTION: 'STATUS_TRANSLATION_ASSUMPTION',
}));

import { STATUS_IMPORT } from '../../actions/importer';
import { TIMELINE_DELETE } from '../../actions/timelines';
import statuses from '../statuses';
import translationAssumptions from '../translation_assumptions';

const STATUS_TRANSLATION_ASSUMPTION = 'STATUS_TRANSLATION_ASSUMPTION';

describe('translation language-pair assumptions', () => {
  it('stores a viewer pair without changing the status language', () => {
    const state = fromJS({
      s1: {
        id: 's1',
        language: 'en',
        translationMode: 'translated',
        translation: { language: 'ja', detected_source_language: 'en', provider: 'DeepL' },
      },
    });

    const assumptions = translationAssumptions(undefined, {
      type: STATUS_TRANSLATION_ASSUMPTION,
      id: 's1',
      source: 'fr',
      target: 'de',
    });
    const next = statuses(state, {
      type: STATUS_TRANSLATION_ASSUMPTION,
      id: 's1',
      source: 'fr',
      target: 'de',
    });

    expect(assumptions.getIn(['s1', 'source'])).toBe('fr');
    expect(assumptions.getIn(['s1', 'target'])).toBe('de');
    expect(assumptions.has('s2')).toBe(false);
    expect(next.getIn(['s1', 'language'])).toBe('en');
    expect(next.getIn(['s1', 'translationMode'])).toBe('original');
    expect(next.getIn(['s1', 'translation', 'provider'])).toBe('DeepL');
  });

  it('keeps the pair when the status is reimported and drops it when the status is removed', () => {
    const stored = translationAssumptions(undefined, {
      type: STATUS_TRANSLATION_ASSUMPTION,
      id: 's1',
      source: 'zh',
      target: 'ja',
    });
    const reimported = translationAssumptions(stored, {
      type: STATUS_IMPORT,
      status: { id: 's1', language: 'en' },
    });
    const removed = translationAssumptions(reimported, {
      type: TIMELINE_DELETE,
      id: 's1',
      references: ['s2'],
    });

    expect(reimported.getIn(['s1', 'source'])).toBe('zh');
    expect(removed.has('s1')).toBe(false);
  });
});
