import { toServerSideType } from '../utils/filters';

// The column type that the original timeline would give to StatusList.
// toServerSideType('mix:<uuid>') is public, which would drop home filters
// from home and list posts. P2 must filter with this context per source.
const columnTypeForSource = (source) => {
  switch (source.type) {
  case 'home':
    return 'home';
  case 'list':
    return `list:${source.id || ''}`;
  case 'account':
    return 'account';
  case 'limited':
    return 'limited';
  case 'personal':
    return 'personal';
  case 'public':
  case 'remote':
    return 'public';
  case 'domain':
    return source.domain ? `domain:${source.domain}` : 'domain';
  case 'hashtag':
    return source.id ? `hashtag:${source.id}` : 'hashtag';
  case 'group':
    return source.id ? `group:${source.id}` : 'group';
  default:
    return null;
  }
};

export const mixTimelineId = (mixId) => `mix:${mixId}`;

export const filterContextForSource = (source) => {
  const plain = source && typeof source.toJS === 'function' ? source.toJS() : source;

  if (!plain || !plain.type) {
    return null;
  }

  const columnType = columnTypeForSource(plain);

  if (!columnType) {
    return null;
  }

  return toServerSideType(columnType);
};
