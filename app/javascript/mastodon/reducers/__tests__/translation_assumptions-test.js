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
  STATUS_TRANSLATION_TARGET: 'STATUS_TRANSLATION_TARGET',
}));

import { STATUS_IMPORT } from '../../actions/importer';
import { TIMELINE_DELETE } from '../../actions/timelines';
import statuses from '../statuses';
import translationAssumptions from '../translation_assumptions';

const STATUS_TRANSLATION_ASSUMPTION = 'STATUS_TRANSLATION_ASSUMPTION';

describe('translation language-pair assumptions', () => {
  it('stores only the source and leaves the status language unchanged', () => {
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

    expect(assumptions.get('s1')).toBe('fr');
    expect(assumptions.getIn(['s1', 'source'])).toBeUndefined();
    expect(assumptions.getIn(['s1', 'target'])).toBeUndefined();
    expect(assumptions.has('s2')).toBe(false);
    expect(next.getIn(['s1', 'language'])).toBe('en');
    expect(next.getIn(['s1', 'translationMode'])).toBe('original');
    expect(next.getIn(['s1', 'translation', 'provider'])).toBe('DeepL');
    expect(next.getIn(['s1', 'translationPending'])).toBe(false);
    expect(next.getIn(['s1', 'translationRequestId'])).toBeUndefined();
  });

  it('keeps each source across reimport and drops only the removed status', () => {
    const stored = translationAssumptions(undefined, {
      type: STATUS_TRANSLATION_ASSUMPTION,
      id: 's1',
      source: 'zh',
      target: 'ja',
    });
    const withOther = translationAssumptions(stored, {
      type: STATUS_TRANSLATION_ASSUMPTION,
      id: 's2',
      source: 'de',
    });
    const reimported = translationAssumptions(withOther, {
      type: STATUS_IMPORT,
      status: { id: 's1', language: 'en' },
    });
    const removed = translationAssumptions(reimported, {
      type: TIMELINE_DELETE,
      id: 's1',
      references: [],
    });

    expect(reimported.get('s1')).toBe('zh');
    expect(reimported.get('s2')).toBe('de');
    expect(removed.has('s1')).toBe(false);
    expect(removed.get('s2')).toBe('de');
  });

  it('also drops assumptions for referenced statuses', () => {
    const stored = translationAssumptions(translationAssumptions(undefined, {
      type: STATUS_TRANSLATION_ASSUMPTION,
      id: 's1',
      source: 'zh',
    }), {
      type: STATUS_TRANSLATION_ASSUMPTION,
      id: 's2',
      source: 'de',
    });
    const removed = translationAssumptions(stored, {
      type: TIMELINE_DELETE,
      id: 's1',
      references: ['s2'],
    });

    expect(removed.has('s1')).toBe(false);
    expect(removed.has('s2')).toBe(false);
  });
});
