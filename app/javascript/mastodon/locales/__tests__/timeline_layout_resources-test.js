import english from '../en.json';
import japanese from '../ja.json';
import defaultMessages from '../defaultMessages.json';

const layoutMessages = {
  'column_header.layout.label': '表示方法',
  'column_header.layout.normal': '通常',
  'column_header.layout.card_1': 'カード（1列）',
  'column_header.layout.card_2': 'カード（2列）',
  'column_header.layout.card_3': 'カード（3列）',
  'column_header.layout.media': 'メディア',
  'timeline.media.reveal': 'メディアを表示',
  'timeline.media.open': 'メディアを開く',
  'timeline.media.open_post': '元の投稿を開く',
};

describe('Timeline layout translation resources', () => {
  it('includes complete Japanese and English resources for all layout controls', () => {
    Object.entries(layoutMessages).forEach(([id, japaneseMessage]) => {
      expect(japanese[id]).toBe(japaneseMessage);
      expect(english[id]).toEqual(expect.any(String));
      expect(english[id].trim()).not.toBe('');
    });
  });

  it('includes every layout descriptor in the translation source catalog', () => {
    const allIds = defaultMessages.reduce((ids, group) => {
      (group.descriptors || []).forEach(item => ids.add(item.id));
      return ids;
    }, new Set());

    Object.keys(layoutMessages).forEach(id => {
      expect(allIds.has(id)).toBe(true);
    });
  });
});
