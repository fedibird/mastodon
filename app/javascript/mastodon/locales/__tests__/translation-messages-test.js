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

const composerLanguageMessageIds = [
  'compose.language.change',
  'compose.language.search',
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

  it('defines the composer language picker messages in English and Japanese', () => {
    composerLanguageMessageIds.forEach((id) => {
      expect(en[id]).toEqual(expect.any(String));
      expect(ja[id]).toEqual(expect.any(String));
      expect(en[id]).not.toBe('');
      expect(ja[id]).not.toBe('');
    });

    expect(formatMessage(ja, { id: 'compose.language.change', defaultMessage: 'Change language' })).toBe('言語を変更');
    expect(formatMessage(ja, { id: 'compose.language.search', defaultMessage: 'Search languages...' })).toBe('言語を検索...');
    expect(formatMessage(en, { id: 'compose.language.change', defaultMessage: 'Change language' })).toBe('Change language');
    expect(formatMessage(en, { id: 'compose.language.search', defaultMessage: 'Search languages...' })).toBe('Search languages...');
  });

  it('defines admin report notification messages in English and Japanese', () => {
    const ids = [
      'notification.admin.report',
      'report_notification.attached_statuses',
      'report_notification.categories.legal',
      'report_notification.categories.other',
      'report_notification.categories.spam',
      'report_notification.categories.violation',
      'report_notification.open',
    ];

    ids.forEach((id) => {
      expect(en[id]).toEqual(expect.any(String));
      expect(ja[id]).toEqual(expect.any(String));
      expect(en[id]).not.toBe('');
      expect(ja[id]).not.toBe('');
    });

    expect(en['notification.admin.report']).toBe('{name} reported {target}');
    expect(ja['notification.admin.report']).toBe('{name}さんが{target}さんを通報しました');
    expect(en['report_notification.open']).toBe('Open report');
    expect(ja['report_notification.open']).toBe('通報を開く');
    expect(ja['report_notification.categories.spam']).toBe('スパム');
    expect(ja['report_notification.categories.legal']).toBe('法令違反');
    expect(ja['report_notification.categories.violation']).toBe('ルール違反');
    expect(ja['report_notification.categories.other']).toBe('その他');
  });

  it('uses Japanese for the Chinese script guidance', () => {
    const defaultMessage = 'Choose Simplified Chinese or Traditional Chinese as the source language.';

    expect(formatMessage(ja, { id: 'status.translation_choose_chinese_script', defaultMessage })).toBe('翻訳元の言語として簡体字中国語または繁体字中国語を選択してください。');
    expect(formatMessage(en, { id: 'status.translation_choose_chinese_script', defaultMessage })).toBe(defaultMessage);
  });
});
