import { fromJS } from 'immutable';

import {
  normalizeTranslationBarVisibility,
  normalizeTranslationPreferredMode,
  preTranslationRequestModes,
  translationBarEffectivelyVisible,
} from '../translation_view';

const languages = fromJS({
  en: ['ja', 'fr'],
  ja: ['en'],
  fr: ['ja'],
  und: ['en'],
  'zh-Hans': ['ja'],
  'zh-Hant': ['ja'],
});

const visible = (visibility, source, target, revealed = false) => translationBarEffectivelyVisible({
  visibility,
  revealed,
  source,
  target,
  translationLanguages: languages,
});

describe('translation bar visibility', () => {
  it('shows a target-mode bar only when the viewer source and target differ', () => {
    expect(visible('target', 'ja', 'ja')).toBe(false);
    expect(visible('target', 'en', 'ja')).toBe(true);
    expect(visible('target', 'fr', 'ja')).toBe(true);
    expect(visible('target', 'und', 'ja')).toBe(true);
    expect(visible('target', 'zh', 'ja')).toBe(true);
    expect(visible('target', 'zh', 'zh-Hans')).toBe(true);
    expect(visible('target', 'zh-Hans', 'zh-Hant')).toBe(true);
  });

  it('treats always, never, and a per-status reveal independently of provider support', () => {
    expect(visible('always', 'ja', 'ja')).toBe(true);
    expect(visible('never', 'en', 'ja')).toBe(false);
    expect(visible('never', 'en', 'ja', true)).toBe(true);
    expect(visible('target', 'ja', 'ja', true)).toBe(true);
    expect(visible(null, 'en', 'ja')).toBe(false);
  });

  it('normalizes visibility and pre-translation actions', () => {
    expect(normalizeTranslationBarVisibility('always')).toBe('always');
    expect(normalizeTranslationBarVisibility('target')).toBe('target');
    expect(normalizeTranslationBarVisibility('never')).toBe('never');
    expect(normalizeTranslationBarVisibility(true)).toBeNull();
    expect(normalizeTranslationBarVisibility('nope')).toBeNull();

    expect(normalizeTranslationPreferredMode('both')).toBe('both');
    expect(normalizeTranslationPreferredMode('bilingual')).toBe('bilingual');
    expect(normalizeTranslationPreferredMode('nope')).toBe('translated');
    expect(preTranslationRequestModes('translated')).toEqual(['translated']);
    expect(preTranslationRequestModes('bilingual')).toEqual(['bilingual']);
    expect(preTranslationRequestModes('both')).toEqual(['translated', 'bilingual']);
  });
});
