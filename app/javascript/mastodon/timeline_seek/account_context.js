import { HISTORY_EDGE } from '../windowed_history/constants';

export const ACCOUNT_CONTEXT_OPEN = 'ACCOUNT_CONTEXT_OPEN';
export const ACCOUNT_CONTEXT_CLOSE = 'ACCOUNT_CONTEXT_CLOSE';

export const ACCOUNT_CONTEXT_PREFIX = 'account-context:';

const HOST_BODY = /^[0-9A-Za-z:_-]{1,180}$/;

// Reply quotes and references need replies included. A boost is the wrapper
// row, so reblogs stay in that source. Caller flags are explicit: this does
// not read the profile column settings.
export const accountContextFilters = ({ reply = false, reblog = false, tagged = '', onlyMedia = false } = {}) => ({
  excludeReplies: !reply,
  excludeReblogs: !reblog,
  tagged: typeof tagged === 'string' ? tagged : '',
  onlyMedia: !!onlyMedia,
});

export const accountContextHostId = (hostKey) => {
  if (typeof hostKey !== 'string' || hostKey.length === 0) {
    return null;
  }

  const body = hostKey.indexOf(ACCOUNT_CONTEXT_PREFIX) === 0
    ? hostKey.slice(ACCOUNT_CONTEXT_PREFIX.length)
    : hostKey;

  if (!HOST_BODY.test(body)) {
    return null;
  }

  return `${ACCOUNT_CONTEXT_PREFIX}${body}`;
};

// No live boundary. A seek may land on any id the account source resolves.
export const emptyAccountContextWindow = () => ({
  generation: 0,
  revision: 0,
  anchorId: null,
  anchorResolution: 'missing',
  unbounded: false,
  boundaryId: null,
  newestId: null,
  oldestId: null,
  hasNewer: true,
  hasOlder: true,
  seeking: false,
  newer: { status: HISTORY_EDGE.OPEN, requestId: null, cursor: null },
  older: { status: HISTORY_EDGE.OPEN, requestId: null, cursor: null },
});
