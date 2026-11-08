import { firstGrapheme } from '../emoji_stock';

export const MAX_CATEGORIES = 50;
export const MAX_CATEGORY_ITEMS = 200;
export const MAX_ITEMS = 1000;

export const itemIdentity = item => item.kind === 'custom' ? `custom:${item.custom_emoji_id || item.shortcode}` : `unicode:${item.native}`;

export const itemCount = categories => categories.reduce((total, category) => total + category.items.length, 0);

export function moveEntry(entries, id, destination) {
  const source = entries.findIndex(entry => entry.id === id);

  if (source < 0 || destination < 0 || destination >= entries.length || source === destination) {
    return entries;
  }

  const result = entries.slice();
  result.splice(destination, 0, result.splice(source, 1)[0]);
  return result;
}

export function removeItem(category, id) {
  return {
    ...category,
    heading: category.heading.mode === 'emoji' && category.heading.item_id === id ? { mode: 'first' } : category.heading,
    items: category.items.filter(item => item.id !== id),
  };
}

export function representativeItem(category) {
  if (!category || category.heading.mode === 'initial') {
    return null;
  }

  if (category.heading.mode === 'emoji') {
    return category.items.find(item => item.id === category.heading.item_id) || null;
  }

  return category.items[0] || null;
}

export function categoryHeading(category, resolvedItems) {
  const item = representativeItem(category);
  const resolved = item && resolvedItems[item.id];
  const heading = { text: firstGrapheme(category.name.trim()) || '…' };

  if (resolved && resolved.available && resolved.image) {
    heading.image = resolved.image;
  }

  return heading;
}

// Resolve headings from the original definition before omitting unavailable
// placements. Search and preview must never silently select a new first item.
export function draftStock(categories, resolvedItems) {
  return {
    categories: categories.map(category => ({
      id: category.id,
      name: category.name,
      heading: categoryHeading(category, resolvedItems),
      items: category.items.reduce((items, item) => {
        const resolved = resolvedItems[item.id];

        if (resolved && resolved.available && resolved.selection && resolved.image) {
          items.push({
            key: item.id,
            label: resolved.label,
            image: resolved.image,
            search: resolved.search,
            selection: resolved.selection,
          });
        }

        return items;
      }, []),
    })),
  };
}

export function draftSnapshot(categories, pickerSize) {
  return JSON.stringify({ categories, picker_emoji_size: pickerSize });
}

export const itemLabel = (item, resolvedItems) => resolvedItems[item.id]?.label || item.shortcode || item.native || item.emoji_id;
