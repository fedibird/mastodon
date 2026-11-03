import { List as ImmutableList } from 'immutable';
import { mediaIsConcealed } from './media_display';

// Navigation follows the timeline's loaded, rendered order across posts.
// Do not silently reveal sensitive media via the next/previous controls.
export const mediaTimelineSequence = (rows = [], statuses, visibility = 'hide_sensitive') => {
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
    if (mediaIsConcealed(visibility, shown.get('sensitive'))) {
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
