import english from '../en.json';
import japanese from '../ja.json';
import defaultMessages from '../defaultMessages.json';

const layoutMessages = {
  'column_width.x200': '200%',
  'media_display.toolbar': 'メディアの表示設定',
  'media_display.shape': '表示形式',
  'media_display.square': 'スクエア',
  'media_display.original': 'オリジナル',
  'media_display.size': 'メディアのサイズ',
  'media_display.small': '小',
  'media_display.medium': '中',
  'media_display.large': '大',
  'media_display.max': '最大',
  'media_display.visibility': '表示設定の一時上書き（このカラムのみ）',
  'media_display.hide_sensitive': '閲覧注意メディアを隠す',
  'media_display.show_all': 'メディアを常に表示する',
  'media_display.hide_all': 'メディアを常に隠す',
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
