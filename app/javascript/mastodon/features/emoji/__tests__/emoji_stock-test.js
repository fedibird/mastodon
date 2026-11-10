import {
  emptyEmojiStock,
  firstGrapheme,
  isEmptyEmojiStock,
  normalizeEmojiStockLoad,
  normalizeSearchKey,
  prepareEmojiStock,
  searchEmojiStock,
  toEmojiPickerCallbackPayload,
} from '../emoji_stock';

const SKIN = '👍\u{1F3FB}';
const ZWJ = '👩\u200d👩\u200d👦\u200d👦';
const VARIATION = '#\uFE0F\u20E3';

const deepFreeze = value => {
  if (!value || typeof value !== 'object' || Object.isFrozen(value)) {
    return value;
  }

  Object.keys(value).forEach(key => deepFreeze(value[key]));
  return Object.freeze(value);
};

const stock = () => ({
  categories: [
    {
      id: 'cat-z',
      name: 'Zebra',
      items: [
        {
          key: 'place-zwj',
          label: 'Family',
          image: { src: 'https://assets.example/family.svg', alt: ZWJ },
          search: ['Family', 'かぞく', ZWJ],
          selection: { id: 'woman-woman-boy-boy', custom: false, native: ZWJ },
        },
        {
          key: 'place-skin',
          label: 'Thumb light',
          image: { src: 'https://assets.example/thumb-light.svg', alt: SKIN },
          search: ['Thumb light', '+1', 'いいね'],
          selection: { id: '+1', custom: false, native: SKIN },
        },
      ],
    },
    {
      id: 'cat-a',
      name: 'Apple',
      items: [
        {
          key: 'place-plain',
          label: 'Thumb',
          image: { src: 'https://assets.example/thumb.svg', alt: '👍' },
          search: ['Thumb', '+1'],
          selection: { id: '+1', custom: false, native: '👍' },
        },
        {
          key: 'place-custom',
          label: 'Fedibird',
          image: { src: 'https://cdn.example/fedibird.png', alt: ':fedibird@example.com:' },
          search: ['Fedibird', 'fedibird', ':fedibird@example.com:'],
          selection: {
            id: 'fedibird@example.com',
            custom: true,
            colons: ':fedibird@example.com:',
            native: ':fedibird@example.com:',
          },
        },
        {
          key: 'place-zwj-again',
          label: 'Family again',
          image: { src: 'https://assets.example/family.svg', alt: ZWJ },
          search: ['Family again', ZWJ],
          selection: { id: 'woman-woman-boy-boy', custom: false, native: ZWJ },
        },
        {
          key: 'place-hash',
          label: 'Hash',
          image: { src: 'https://assets.example/hash.svg', alt: VARIATION },
          search: ['Hash', VARIATION],
          selection: { id: 'hash', custom: false, native: VARIATION },
        },
      ],
    },
  ],
});

describe('emoji stock contract', () => {
  it('keeps the resolved heading when search hides its representative', () => {
    const value = stock();

    value.categories[0].heading = { text: 'Z', image: value.categories[0].items[0].image };
    const frozen = deepFreeze(value);
    const result = searchEmojiStock(frozen, 'Thumb light');

    expect(result.categories[0].items.map(item => item.key)).toEqual(['place-skin']);
    expect(result.categories[0].heading).toBe(frozen.categories[0].heading);
    expect(result.categories[0].heading.image.src).toContain('family.svg');
  });

  it('takes a whole first grapheme for category names', () => {
    expect(firstGrapheme('横長')).toBe('横');
    expect(firstGrapheme('Long')).toBe('L');
    expect(firstGrapheme(`${ZWJ} family`)).toBe(ZWJ);
    expect(firstGrapheme(`${SKIN} thumbs`)).toBe(SKIN);
    expect(firstGrapheme('e\u0301clair')).toBe('e\u0301');
    expect(firstGrapheme('か\u3099く')).toBe('か\u3099');
  });

  it('keeps combining marks and emoji sequences without Intl.Segmenter', () => {
    const segmenter = Intl.Segmenter;

    try {
      Intl.Segmenter = undefined;
      expect(firstGrapheme('か\u3099く')).toBe('か\u3099');
      expect(firstGrapheme(`${ZWJ} family`)).toBe(ZWJ);
      expect(firstGrapheme(`${SKIN} thumbs`)).toBe(SKIN);
      expect(firstGrapheme('')).toBe('');
    } finally {
      Intl.Segmenter = segmenter;
    }
  });

  it('keeps category order, item order, duplicate placements, and skin variants', () => {
    const frozen = deepFreeze(stock());
    const visible = searchEmojiStock(frozen, '');

    expect(visible.categories.map(category => category.id)).toEqual(['cat-z', 'cat-a']);
    expect(visible.categories[0].items.map(item => item.key)).toEqual(['place-zwj', 'place-skin']);
    expect(visible.categories[1].items.map(item => item.selection.id)).toEqual([
      '+1',
      'fedibird@example.com',
      'woman-woman-boy-boy',
      'hash',
    ]);
    expect(visible.categories[0].items[1].selection.native).toBe(SKIN);
    expect(visible.categories[1].items[0].selection.native).toBe('👍');
    expect(frozen.categories[0].items).toHaveLength(2);
    expect(frozen.categories[1].items).toHaveLength(4);
  });

  it('prepares immutable stock for searching and handles new revisions independently', () => {
    const original = deepFreeze(stock());
    const updated = stock();

    updated.categories[0].items[0].search.push('新しい別名');
    expect(prepareEmojiStock(original)).toBe(original);
    expect(prepareEmojiStock(original)).toBe(original);
    expect(searchEmojiStock(original, 'かぞく').categories[0].items[0].key).toBe('place-zwj');
    expect(searchEmojiStock(original, '新しい別名').categories).toEqual([]);
    expect(prepareEmojiStock(updated)).toBe(updated);
    expect(searchEmojiStock(updated, '新しい別名').categories[0].items[0].key).toBe('place-zwj');
  });

  it('searches only stock terms and keeps the registered order', () => {
    const frozen = deepFreeze(stock());

    expect(normalizeSearchKey('  Thumb   Light ')).toBe('thumblight');

    const thumbs = searchEmojiStock(frozen, 'THUMB');
    const spaced = searchEmojiStock(frozen, 'thumb   light');
    const families = searchEmojiStock(frozen, 'かぞく');
    const missing = searchEmojiStock(frozen, 'pineapple');

    expect(thumbs.categories.map(category => category.items.map(item => item.key))).toEqual([
      ['place-skin'],
      ['place-plain'],
    ]);
    expect(spaced.categories.map(category => category.items.map(item => item.key))).toEqual([
      ['place-skin'],
    ]);
    expect(families.categories.map(category => category.items.map(item => item.key))).toEqual([
      ['place-zwj'],
    ]);
    expect(missing.categories).toEqual([]);
    expect(frozen.categories[0].items[1].selection.native).toBe(SKIN);
    expect(searchEmojiStock(frozen, SKIN).categories[0].items[0].key).toBe('place-skin');
  });

  it('copies a callback payload and leaves unicode strings untouched', () => {
    const frozen = deepFreeze(stock());
    const skin = frozen.categories[0].items[1];
    const custom = frozen.categories[1].items[1];
    const zwj = frozen.categories[0].items[0];
    const hash = frozen.categories[1].items[3];
    const first = toEmojiPickerCallbackPayload(skin);
    const second = toEmojiPickerCallbackPayload(skin);

    expect(first).not.toBe(second);
    expect(first).not.toBe(skin.selection);
    expect(first).toEqual({ id: '+1', custom: false, native: SKIN });
    expect(first.id).not.toBe(skin.key);
    expect(first.id).not.toBe('cat-z');

    first.native = 'changed';
    first.id = 'changed';

    expect(toEmojiPickerCallbackPayload(skin)).toEqual({ id: '+1', custom: false, native: SKIN });
    expect(skin.selection.native).toBe(SKIN);
    expect(toEmojiPickerCallbackPayload(frozen.categories[1].items[0]).native).toBe('👍');
    expect(toEmojiPickerCallbackPayload(zwj).native).toBe(ZWJ);
    expect(toEmojiPickerCallbackPayload(hash).native).toBe(VARIATION);
    expect(toEmojiPickerCallbackPayload(custom)).toEqual({
      id: 'fedibird@example.com',
      custom: true,
      native: ':fedibird@example.com:',
      colons: ':fedibird@example.com:',
    });
  });

  it('treats a ready empty stock as success and an error as failure', () => {
    const empty = emptyEmojiStock();

    expect(isEmptyEmojiStock(empty)).toBe(true);
    expect(normalizeEmojiStockLoad({ status: 'ready', stock: empty })).toEqual({ status: 'ready', stock: empty });
    expect(normalizeEmojiStockLoad({ status: 'ready' }).stock).toEqual(empty);

    const error = new Error('offline');

    expect(normalizeEmojiStockLoad({ status: 'error', error })).toEqual({ status: 'error', error });
    expect(normalizeEmojiStockLoad({ status: 'error' }).status).toBe('error');
    expect(normalizeEmojiStockLoad(null).status).toBe('error');
  });
});
