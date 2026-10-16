import { normalizeStatusIds } from './surface';

const statusTypes = new Set(['mention', 'favourite', 'reblog', 'status', 'scheduled_status', 'poll', 'emoji_reaction', 'status_reference', 'update']);
export const notificationStatusForRow = (items, rowId) => items?.find(item => item && item.get('id') === rowId && statusTypes.has(item.get('type')))?.get('status');
export const notificationStatusIds = items => normalizeStatusIds([items?.filter(item => item && statusTypes.has(item.get('type'))).map(item => item.get('status'))]);
