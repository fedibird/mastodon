import { is } from 'immutable';
import { STATUS_IMPORT, STATUSES_IMPORT, POLLS_IMPORT } from '../actions/importer';
import { TIMELINE_DELETE, TIMELINE_EXPIRE } from '../actions/timelines';

const fields = ['content', 'spoiler_text', 'edited_at', 'account', 'reblog', 'quote_id', 'poll', 'url', 'uri', 'references', 'status_reference_ids', 'visibility', 'expired_at', 'deleted_at'];
const mediaText = status => status?.get('media_attachments')?.map(media => media.filter((_, key) => key === 'id' || key === 'description'));
const pollText = poll => poll?.get('options')?.map(option => option.get('title'));

const sameContent = (previous, next, id) => {
  const before = previous.getIn(['statuses', id]);
  const after = next.getIn(['statuses', id]);
  if (before !== after && (!before || !after || fields.some(field => !is(before.get(field), after.get(field))) || !is(mediaText(before), mediaText(after)))) return false;
  const beforePoll = previous.getIn(['polls', before?.get('poll')]);
  const afterPoll = next.getIn(['polls', after?.get('poll')]);
  return beforePoll === afterPoll || is(pollText(beforePoll), pollText(afterPoll));
};

// Inspect only the bounded overlay, never enumerate timelines or all statuses.
// No text/media snapshots are copied into the overlay. Invalidating requestId
// also rejects responses sent before an edit, even if the body later reverts.
export const maintainFilterMatchContent = (previous, next, action) => {
  if (!previous || ![STATUS_IMPORT, STATUSES_IMPORT, POLLS_IMPORT, TIMELINE_DELETE, TIMELINE_EXPIRE].includes(action.type)) return next;
  const entries = next.getIn(['filterMatches', 'entries']);
  const removed = action.type === TIMELINE_DELETE || action.type === TIMELINE_EXPIRE;
  if (!removed && previous.get('statuses') === next.get('statuses') && previous.get('polls') === next.get('polls')) return next;
  const updated = entries.withMutations(map => {
    entries.forEach((entry, id) => {
      const beforeOriginal = previous.getIn(['statuses', id, 'reblog']);
      const afterOriginal = next.getIn(['statuses', id, 'reblog']);
      if (removed && (id === action.id || beforeOriginal === action.id || action.references?.includes(id))) {
        map.delete(id);
      } else if (!sameContent(previous, next, id) || (beforeOriginal && !sameContent(previous, next, beforeOriginal)) || (afterOriginal && afterOriginal !== beforeOriginal && !sameContent(previous, next, afterOriginal))) {
        map.set(id, entry.set('phase', 'unevaluated').delete('requestId').delete('filterIds').delete('resultGeneration'));
      }
    });
  });
  return updated === entries ? next : next.setIn(['filterMatches', 'entries'], updated);
};
