import {
  domainHistoryContract,
  groupHistoryContract,
  hashtagHistoryContract,
  homeHistoryContract,
  limitedHistoryContract,
  listHistoryContract,
  personalHistoryContract,
  publicHistoryContract,
} from '../windowed_history/sources';
import { CLOSED_SOURCES, SEEK_CAPABILITY, SEEK_KIND } from './constants';

const entry = (level, reason) => Object.freeze({ level, reason });

const redisStatus = entry(SEEK_CAPABILITY.APPROXIMATE, 'redis_retained_window');
const redisDate = entry(SEEK_CAPABILITY.APPROXIMATE, 'redis_id_probe_not_created_at');
const redisAccount = entry(SEEK_CAPABILITY.APPROXIMATE, 'account_probe_limit');
const redisSearch = entry(SEEK_CAPABILITY.APPROXIMATE, 'search_hit_checks_retained_membership');
const dbStatus = entry(SEEK_CAPABILITY.SUPPORTED, 'source_scope_point_lookup');
const dbDate = entry(SEEK_CAPABILITY.APPROXIMATE, 'id_order_not_created_at');
const dbAccount = entry(SEEK_CAPABILITY.APPROXIMATE, 'account_probe_limit');
const dbSearch = entry(SEEK_CAPABILITY.SUPPORTED, 'search_hit_checks_membership_only');
const personalAccount = entry(SEEK_CAPABILITY.UNSUPPORTED, 'personal_is_not_an_account_timeline');
const closed = entry(SEEK_CAPABILITY.UNSUPPORTED, 'source_has_no_windowed_history');

// Same cells as TimelineSeek::Capability. Levels are not upgraded on the client.
const MATRIX = Object.freeze({
  home: Object.freeze({ status: redisStatus, date: redisDate, account: redisAccount, searchHit: redisSearch }),
  limited: Object.freeze({ status: redisStatus, date: redisDate, account: redisAccount, searchHit: redisSearch }),
  list: Object.freeze({ status: redisStatus, date: redisDate, account: redisAccount, searchHit: redisSearch }),
  hashtag: Object.freeze({ status: dbStatus, date: dbDate, account: dbAccount, searchHit: dbSearch }),
  public: Object.freeze({ status: dbStatus, date: dbDate, account: dbAccount, searchHit: dbSearch }),
  domain: Object.freeze({ status: dbStatus, date: dbDate, account: dbAccount, searchHit: dbSearch }),
  group: Object.freeze({ status: dbStatus, date: dbDate, account: dbAccount, searchHit: dbSearch }),
  personal: Object.freeze({ status: dbStatus, date: dbDate, account: personalAccount, searchHit: dbSearch }),
});

export const windowedHistoryContracts = () => ([
  homeHistoryContract([]),
  limitedHistoryContract([]),
  listHistoryContract('1'),
  hashtagHistoryContract('news', { any: [{ value: 'fedibird' }], all: [], none: [] }),
  publicHistoryContract({ onlyRemote: true, onlyMedia: false, withoutMedia: false, withoutBot: true }),
  domainHistoryContract('example.com', { onlyMedia: false, withoutMedia: false, withoutBot: false }),
  groupHistoryContract('1', { onlyMedia: false, withoutMedia: false, tagged: 'photos' }),
  personalHistoryContract({ onlyMedia: false, withoutMedia: false }),
]);

export const capabilityFor = (source, kind) => {
  if (CLOSED_SOURCES.indexOf(source) !== -1) {
    return closed;
  }

  const row = MATRIX[source];

  if (!row) {
    return entry(SEEK_CAPABILITY.UNSUPPORTED, 'unknown_source');
  }

  return row[kind] || entry(SEEK_CAPABILITY.UNSUPPORTED, 'unknown_kind');
};

export const capabilityMatrix = () => MATRIX;

export const seekKinds = () => Object.keys(SEEK_KIND).map(key => SEEK_KIND[key]);
