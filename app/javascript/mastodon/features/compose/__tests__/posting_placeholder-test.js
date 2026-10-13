import { postingPlaceholderText, isAutoPostingLanguage, textareaLanguage } from '../posting_placeholder';
import { POSTING_PLACEHOLDERS } from '../posting_placeholders';

const format = (text, language, uiLocale) => (
  uiLocale === 'ja' ? `${text}（${language}）` : `${text} (${language})`
);

describe('posting placeholders', () => {
  it('uses the posting-language sentence and a UI-language name', () => {
    expect(isAutoPostingLanguage(null)).toBe(true);
    expect(isAutoPostingLanguage('')).toBe(true);
    expect(isAutoPostingLanguage('und')).toBe(true);
    expect(textareaLanguage('und')).toBeUndefined();
    expect(textareaLanguage('en')).toBe('en');

    expect(format(POSTING_PLACEHOLDERS.ja, '日本語', 'ja')).toBe('今なにしてる？（日本語）');
    expect(format(POSTING_PLACEHOLDERS.en, '英語', 'ja')).toBe('What\'s on your mind?（英語）');
    expect(format(POSTING_PLACEHOLDERS.ja, 'Japanese', 'en')).toBe('今なにしてる？ (Japanese)');
    expect(format(POSTING_PLACEHOLDERS.ja, '自動判定', 'ja')).toBe('今なにしてる？（自動判定）');
    expect(format(POSTING_PLACEHOLDERS.en, 'Auto-detect', 'en')).toBe('What\'s on your mind? (Auto-detect)');
    expect(postingPlaceholderText('fr')).toBe(POSTING_PLACEHOLDERS.fr);
    expect(postingPlaceholderText('fr')).not.toBe(POSTING_PLACEHOLDERS.en);
  });

  it('falls back when the posting language has no translated placeholder', () => {
    expect(postingPlaceholderText('af')).toBeNull();
    expect(postingPlaceholderText('xx')).toBeNull();
    expect(POSTING_PLACEHOLDERS.af).toBeUndefined();
  });
});
