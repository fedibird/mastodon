import { List as ImmutableList } from 'immutable';
import { accountGalleryAttachments } from 'mastodon/selectors';
import { mediaRowsForStatuses } from 'mastodon/utils/timeline_layout';
import { accountMediaTimelineSequence, mediaTimelineSequence } from 'mastodon/utils/media_timeline_sequence';

// The modal owns the initial sequence snapshot. A new Redux page is appended
// only after the last status that had already loaded when it opened.
// That preserves the selected index, attribution, and intentional filtering
// of the initial sequence, even when an older page has no usable image.
export const mediaModalPagination = (state, props) => {
  const source = props.mediaSource;
  if (!source || !props.timelineStatusIds) {
    return null;
  }

  const timeline = state.getIn(['timelines', source.timelineId]);
  if (!timeline) {
    return null;
  }

  const statuses = state.get('statuses');
  const ids = timeline.get('items', ImmutableList());
  const anchorIndex = ids.indexOf(source.afterStatusId);
  const tail = anchorIndex >= 0 ? ids.skip(anchorIndex + 1) : ImmutableList();

  let added;
  if (source.kind === 'account') {
    const account = state.getIn(['accounts', source.accountId]);
    const attachments = accountGalleryAttachments(tail, statuses, account);
    added = accountMediaTimelineSequence(attachments, source.visibility);
  } else {
    const rows = mediaRowsForStatuses(tail, statuses);
    added = mediaTimelineSequence(rows, statuses, source.visibility);
  }

  return {
    media: props.media.concat(added.media),
    statusIds: props.timelineStatusIds.concat(added.statusIds),
    hasMore: !!timeline.get('hasMore'),
    isLoading: !!timeline.get('isLoading'),
    error: !!timeline.get('paginationError'),
  };
};
