import { Set as ImmutableSet } from 'immutable';

import { STATUS_IMPORT, STATUSES_IMPORT } from '../../actions/importer';
import { STATUS_TRANSLATION_BAR_REVEAL } from '../../actions/translation_bar';
import { TIMELINE_DELETE } from '../../actions/timelines';
import translationBarOverrides from '../translation_bar_overrides';

const reveal = (state, id) => translationBarOverrides(state, {
  type: STATUS_TRANSLATION_BAR_REVEAL,
  id,
});

describe('translation bar overrides', () => {
  it('records a status id without storing it on the status', () => {
    const revealed = reveal(undefined, 's1');

    expect(ImmutableSet.isSet(revealed)).toBe(true);
    expect(revealed.has('s1')).toBe(true);
    expect(revealed.has('s2')).toBe(false);
    expect(reveal(revealed).has('s1')).toBe(true);
  });

  it('keeps a reveal across status reimport', () => {
    const revealed = reveal(reveal(undefined, 's1'), 's2');
    const reimported = translationBarOverrides(revealed, {
      type: STATUS_IMPORT,
      status: { id: 's1', language: 'en' },
    });
    const batch = translationBarOverrides(reimported, {
      type: STATUSES_IMPORT,
      statuses: [{ id: 's1', language: 'ja' }, { id: 's2', language: 'fr' }],
    });

    expect(reimported.has('s1')).toBe(true);
    expect(reimported.has('s2')).toBe(true);
    expect(batch.has('s1')).toBe(true);
    expect(batch.has('s2')).toBe(true);
  });

  it('drops the deleted status and its references', () => {
    const revealed = reveal(reveal(reveal(undefined, 's1'), 's2'), 's3');
    const removed = translationBarOverrides(revealed, {
      type: TIMELINE_DELETE,
      id: 's1',
      references: ['s2'],
    });

    expect(removed.has('s1')).toBe(false);
    expect(removed.has('s2')).toBe(false);
    expect(removed.has('s3')).toBe(true);
  });
});
