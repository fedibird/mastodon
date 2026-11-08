import { categoryHeading, draftStock, itemIdentity, moveEntry, removeItem } from '../draft';

describe('personal emoji set drafts', () => {
  const first = { id: 'first', kind: 'custom', custom_emoji_id: '42', shortcode: 'old_banner' };
  const second = { id: 'second', kind: 'unicode', native: '👩🏽‍💻', emoji_id: 'female-technologist' };
  const category = { id: 'greeting', name: '横長', heading: { mode: 'first' }, items: [first, second] };
  const resolved = {
    first: { available: false, label: 'old_banner', reason: 'unavailable' },
    second: { available: true, label: 'Woman technologist', image: { src: '/emoji/1f469-1f3fd-200d-1f4bb.svg', alt: second.native }, search: ['technologist'], selection: { custom: false, id: 'female-technologist', native: second.native } },
  };

  it('retains an unavailable first placement as the heading source and omits it only from selectable stock', () => {
    const stock = draftStock([category], resolved);
    expect(stock.categories[0].heading).toEqual({ text: '横' });
    expect(stock.categories[0].items.map(item => item.key)).toEqual(['second']);
    expect(stock.categories[0].items[0].selection.native).toBe('👩🏽‍💻');
    expect(category.items).toEqual([first, second]);
  });

  it('retains the explicit placement across reorder and resets it only when that placement is removed', () => {
    const explicit = { ...category, heading: { mode: 'emoji', item_id: 'second' } };
    const reordered = { ...explicit, items: moveEntry(explicit.items, 'second', 0) };
    expect(reordered.heading.item_id).toBe('second');
    expect(categoryHeading(reordered, resolved).image.src).toBe(resolved.second.image.src);
    expect(removeItem(reordered, 'first').heading).toEqual(explicit.heading);
    expect(removeItem(reordered, 'second').heading).toEqual({ mode: 'first' });
    expect(explicit.items.map(item => item.id)).toEqual(['first', 'second']);
  });

  it('keeps initial mode on removal and uses one grapheme of the current name', () => {
    const initial = { ...category, name: '👩‍👩‍👧 Family', heading: { mode: 'initial' } };
    expect(categoryHeading(initial, resolved)).toEqual({ text: '👩‍👩‍👧' });
    expect(categoryHeading({ ...initial, name: 'か\u3099ぞく' }, resolved)).toEqual({ text: 'か\u3099' });
    expect(categoryHeading({ ...initial, name: 'Long' }, resolved)).toEqual({ text: 'L' });
    expect(removeItem(initial, 'first').heading).toEqual({ mode: 'initial' });
  });

  it('distinguishes skin tones and stable custom identities, including a reused shortcode', () => {
    expect(itemIdentity({ kind: 'unicode', native: '👍' })).not.toBe(itemIdentity({ kind: 'unicode', native: '👍🏿' }));
    expect(itemIdentity(first)).not.toBe(itemIdentity({ ...first, custom_emoji_id: '43' }));
    expect(itemIdentity({ ...second, id: 'copy' })).toBe(itemIdentity(second));
  });
});
