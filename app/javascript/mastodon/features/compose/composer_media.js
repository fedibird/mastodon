export const COMPACT_MEDIA_PREVIEW_LIMIT = 4;

export function moveMediaIds (ids, id, toIndex) {
  const list = Array.isArray(ids) ? ids.slice() : [];
  const from = list.indexOf(id);

  if (from < 0 || !Number.isInteger(toIndex)) {
    return list;
  }

  const dest = Math.max(0, Math.min(list.length - 1, toIndex));

  if (from === dest) {
    return list;
  }

  const [item] = list.splice(from, 1);
  list.splice(dest, 0, item);

  return list;
}

export function visibleMediaWindow (ids, { summary = false, expanded = false, limit = COMPACT_MEDIA_PREVIEW_LIMIT } = {}) {
  const list = Array.isArray(ids) ? ids : [];

  if (!summary || expanded || list.length <= limit) {
    return { visible: list.slice(), overflow: 0 };
  }

  return {
    visible: list.slice(0, limit),
    overflow: list.length - limit,
  };
}
