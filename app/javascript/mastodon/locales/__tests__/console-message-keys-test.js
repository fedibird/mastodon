import englishMessages from '../en.json';
import japaneseMessages from '../ja.json';

const messageIds = [
  'account_context.boost',
  'account_context.quote',
  'account_context.reference',
  'compose_form.more_actions',
  'notification.admin.sign_up',
  'timeline.reading_bookmarks',
];

const placeholders = message => (message.match(/\{[a-zA-Z][a-zA-Z0-9_]*\}/g) || []).sort();

describe('Messages used by composer, timelines, account context, and notifications', () => {
  it.each(messageIds)('provides Japanese translation and matching ICU placeholders for %s', id => {
    expect(englishMessages[id]).toBeTruthy();
    expect(japaneseMessages[id]).toBeTruthy();
    expect(placeholders(japaneseMessages[id])).toEqual(placeholders(englishMessages[id]));
  });
});
