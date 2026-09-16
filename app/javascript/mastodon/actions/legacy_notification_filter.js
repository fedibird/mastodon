import { getFiltersRegex } from '../selectors';
import { searchTextFromRawStatus } from './importer/normalizer';

// Temporary notification-only helper until PR C switches notifications
// to server-side FilterResult. Do not use this for timeline filtering.
export function legacyNotificationFilterFlags(state, notification) {
  const filters = getFiltersRegex(state, { contextType: 'notifications' });
  let filtered = false;

  if (['mention', 'status', 'scheduled_status', 'status_reference'].includes(notification.type)) {
    const dropRegex   = filters[0];
    const regex       = filters[1];
    const searchIndex = searchTextFromRawStatus(notification.status);

    if (dropRegex && dropRegex.test(searchIndex)) {
      return { drop: true, filtered: false };
    }

    filtered = !!(regex && regex.test(searchIndex));
  }

  return { drop: false, filtered };
}
