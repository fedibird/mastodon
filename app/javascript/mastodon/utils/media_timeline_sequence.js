import { List as ImmutableList } from 'immutable';
import { mediaIsConcealed } from './media_display';
import { mediaStatusFiltered } from './media_filter_visibility';

// A reveal is specific to an image tile, never all attachments of its post.
export const accountMediaRevealKey = item => `${item.getIn(['status', 'id'])}:${item.get('id')}`;

// Navigation follows the timeline's loaded, rendered order across posts.
// Do not silently reveal sensitive media via the next/previous controls.
export const mediaTimelineSequence = (rows = [], statuses, visibility = 'hide_sensitive', filterInfo = {}) => {
  const media = [];
  const statusIds = [];
  const positions = Object.create(null);

  if (!statuses || typeof statuses.get !== 'function') {
    return { media: ImmutableList(), statusIds: ImmutableList(), positions };
  }

  rows.forEach(row => {
    if (!row || row.kind !== 'media') {
      return;
    }

    const base = statuses.get(row.id);
    if (!base || typeof base.get !== 'function') {
      return;
    }

    const reblog = base.get('reblog');
    const shown = (reblog && (typeof reblog.get === 'function' ? reblog : statuses.get(reblog))) || base;
    const context = row.contextType || filterInfo.contextType || 'public';
    if (mediaStatusFiltered(base, shown === base ? null : shown, row.id, context, filterInfo) ||
        mediaIsConcealed(visibility, shown.get('sensitive'), filterInfo.revealedMediaKeys?.has(row.key))) {
      return;
    }

    const attachment = shown.getIn(['media_attachments', row.mediaIndex]);
    if (!attachment || !['image', 'gifv'].includes(attachment.get('type'))) {
      return;
    }

    positions[row.key] = media.length;
    media.push(attachment);
    statusIds.push(shown.get('id') || row.id);
  });

  return { media: ImmutableList(media), statusIds: ImmutableList(statusIds), positions };
};

// Account media gallery uses an attachment-per-tile selector rather than
// normalized timeline status IDs, but it follows the same visibility policy.
export const accountMediaTimelineSequence = (attachments, visibility = 'hide_sensitive', filterInfo = {}) => {
  if (!attachments || typeof attachments.filter !== 'function') {
    return { media: ImmutableList(), statusIds: ImmutableList() };
  }

  const media = attachments.filter(item =>
    item &&
    ['image', 'gifv'].includes(item.get('type')) &&
    !mediaIsConcealed(visibility, item.getIn(['status', 'sensitive']), filterInfo.revealedMediaIds?.has(accountMediaRevealKey(item))) &&
    !mediaStatusFiltered(item.get('status'), null, item.getIn(['status', 'id']), 'account', filterInfo),
  );

  return { media, statusIds: media.map(item => item.getIn(['status', 'id'])) };
};
