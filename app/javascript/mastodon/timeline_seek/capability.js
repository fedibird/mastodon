import {
  accountHistoryContract,
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
const redisMembership = entry(SEEK_CAPABILITY.APPROXIMATE, 'redis_retained_window_batch');
const dbMembership = entry(SEEK_CAPABILITY.SUPPORTED, 'bounded_id_set');
const personalAccount = entry(SEEK_CAPABILITY.UNSUPPORTED, 'personal_is_not_an_account_timeline');
const closed = entry(SEEK_CAPABILITY.UNSUPPORTED, 'source_has_no_windowed_history');
const accountDate = entry(SEEK_CAPABILITY.UNSUPPORTED, 'date_seek_not_implemented');
const accountKind = entry(SEEK_CAPABILITY.UNSUPPORTED, 'account_probe_not_implemented');
const accountSearch = entry(SEEK_CAPABILITY.UNSUPPORTED, 'search_not_implemented');

// Same cells as TimelineSeek::Capability. Levels are not upgraded on the client.
const MATRIX = Object.freeze({
  home: Object.freeze({ status: redisStatus, date: redisDate, account: redisAccount, searchHit: redisSearch, membership: redisMembership }),
  limited: Object.freeze({ status: redisStatus, date: redisDate, account: redisAccount, searchHit: redisSearch, membership: redisMembership }),
  list: Object.freeze({ status: redisStatus, date: redisDate, account: redisAccount, searchHit: redisSearch, membership: redisMembership }),
  hashtag: Object.freeze({ status: dbStatus, date: dbDate, account: dbAccount, searchHit: dbSearch, membership: dbMembership }),
  public: Object.freeze({ status: dbStatus, date: dbDate, account: dbAccount, searchHit: dbSearch, membership: dbMembership }),
  domain: Object.freeze({ status: dbStatus, date: dbDate, account: dbAccount, searchHit: dbSearch, membership: dbMembership }),
  group: Object.freeze({ status: dbStatus, date: dbDate, account: dbAccount, searchHit: dbSearch, membership: dbMembership }),
  personal: Object.freeze({ status: dbStatus, date: dbDate, account: personalAccount, searchHit: dbSearch, membership: dbMembership }),
  account: Object.freeze({ status: dbStatus, date: accountDate, account: accountKind, searchHit: accountSearch, membership: dbMembership }),
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
  accountHistoryContract('1', { excludeReplies: false, excludeReblogs: false, tagged: 'photos', onlyMedia: false }),
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
