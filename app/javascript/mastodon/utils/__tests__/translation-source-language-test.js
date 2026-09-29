import { fromJS } from 'immutable';

import {
  languageOption,
  needsChineseScriptChoice,
  sameTranslationLanguage,
  sourceLanguageOptions,
  targetLanguageOptions,
  translationSourceLanguage,
} from '../translation_languages';

const scriptMap = fromJS({
  'zh-Hans': ['ja', 'en'],
  'zh-Hant': ['ja', 'en'],
  und: ['ja', 'en'],
  en: ['ja'],
});

const preloaded = [
  ['en', 'English', 'English'],
  ['ja', 'Japanese', '日本語'],
  ['zh', 'Chinese', '中文'],
];

describe('translation source language resolution', () => {
  it('keeps bare zh distinct from und and from Chinese scripts', () => {
    expect(translationSourceLanguage('zh', scriptMap)).toBe('zh');
    expect(translationSourceLanguage('ZH', scriptMap)).toBe('zh');
    expect(translationSourceLanguage('und', scriptMap)).toBe('und');
    expect(translationSourceLanguage('zh-Hans', scriptMap)).toBe('zh-Hans');
    expect(translationSourceLanguage('zh-Hant', scriptMap)).toBe('zh-Hant');
    expect(translationSourceLanguage('zh-CN', scriptMap)).toBe('zh-Hans');
    expect(translationSourceLanguage('zh-TW', scriptMap)).toBe('zh-Hant');
    expect(translationSourceLanguage('zh-YUE', scriptMap)).toBe('zh-YUE');
    expect(translationSourceLanguage('zh', fromJS({ 'zh-Hans': ['ja'] }))).toBe('zh');
    expect(translationSourceLanguage('zh', fromJS({ zh: ['ja'], 'zh-Hans': ['en'] }))).toBe('zh');
  });

  it('does not treat zh as the same language as und or a Chinese script', () => {
    expect(sameTranslationLanguage('zh', 'und', scriptMap)).toBe(false);
    expect(sameTranslationLanguage('zh', 'zh-Hans', scriptMap)).toBe(false);
    expect(sameTranslationLanguage('zh', 'zh-Hant', scriptMap)).toBe(false);
    expect(sameTranslationLanguage('zh-Hans', 'zh-Hant', scriptMap)).toBe(false);
    expect(sameTranslationLanguage('zh', 'zh', fromJS({ zh: ['ja'] }))).toBe(true);
    expect(sameTranslationLanguage('zh-Hans', 'zh-Hant', scriptMap)).toBe(false);
  });

  it('asks for a script only for unresolved bare zh', () => {
    expect(needsChineseScriptChoice('zh', scriptMap)).toBe(true);
    expect(needsChineseScriptChoice('zh', fromJS({ zh: ['ja'], 'zh-Hans': ['ja'], und: ['ja'] }))).toBe(false);
    expect(needsChineseScriptChoice('und', scriptMap)).toBe(false);
    expect(needsChineseScriptChoice('zh-Hans', scriptMap)).toBe(false);
    expect(needsChineseScriptChoice('fr', fromJS({ fr: ['de'], 'zh-Hans': ['ja'] }))).toBe(false);
    expect(needsChineseScriptChoice('zh', fromJS({ en: ['ja'], und: ['ja'] }))).toBe(false);
  });

  it('labels Chinese scripts and places them beside bare zh', () => {
    expect(languageOption('zh-Hans', preloaded, 'Unspecified')).toEqual(['zh-Hans', 'Chinese (Simplified)', '简体中文']);
    expect(languageOption('zh-Hant', preloaded, 'Unspecified')).toEqual(['zh-Hant', 'Chinese (Traditional)', '繁體中文']);

    const sourceCodes = sourceLanguageOptions(scriptMap, 'zh', preloaded, 'Unspecified').map(option => option[0]);
    expect(sourceCodes.slice(0, 3)).toEqual(['zh', 'zh-Hans', 'zh-Hant']);

    const targetCodes = targetLanguageOptions(fromJS({ en: ['zh-Hans', 'ja'] }), 'en', 'ja', preloaded, 'Unspecified', 'ja').map(option => option[0]);
    expect(targetCodes).toContain('zh-Hans');
    expect(languageOption('zh-Hans', preloaded, 'Unspecified')[1]).toBe('Chinese (Simplified)');
  });
});
