const fs = require('fs');
const path = require('path');

const en = JSON.parse(fs.readFileSync(path.join(__dirname, '../en.json'), 'utf8'));
const ja = JSON.parse(fs.readFileSync(path.join(__dirname, '../ja.json'), 'utf8'));

const translationMessageIds = [
  'status.translate',
  'status.bilingual',
  'status.original',
  'status.translated',
  'status.translation_modes',
  'status.translation_source_language',
  'status.translation_target_language',
  'status.translation_unspecified',
  'status.translation_unsupported_pair',
  'status.translation_choose_chinese_script',
  'status.translation_detected_source',
  'status.show_translation_bar',
];

const formatMessage = (messages, descriptor) => messages[descriptor.id] || descriptor.defaultMessage;

describe('translation UI locale messages', () => {
  it('defines the translation bar and menu messages in English and Japanese', () => {
    translationMessageIds.forEach((id) => {
      expect(en[id]).toEqual(expect.any(String));
      expect(ja[id]).toEqual(expect.any(String));
      expect(en[id]).not.toBe('');
      expect(ja[id]).not.toBe('');
    });
  });

  it('uses Japanese for the Chinese script guidance', () => {
    const defaultMessage = 'Choose Simplified Chinese or Traditional Chinese as the source language.';

    expect(formatMessage(ja, { id: 'status.translation_choose_chinese_script', defaultMessage })).toBe('翻訳元の言語として簡体字中国語または繁体字中国語を選択してください。');
    expect(formatMessage(en, { id: 'status.translation_choose_chinese_script', defaultMessage })).toBe(defaultMessage);
  });
});
