// Internal built-in Posting Context used by Composer application.
// Not ActivityPub context and not the external Posting Context wire schema.
import { normalizeManagedHashtagName } from './managed_hashtags';

export function buildHashtagTimelinePostingContext(tag) {
  const name = String(tag || '').replace(/^[#＃]+/u, '');
  const normalizedName = normalizeManagedHashtagName(name);

  return {
    key: `builtin:hashtag:${normalizedName}`,

    source: {
      id: 'builtin:hashtag-timeline',
      revision: 1,
    },

    managed: {
      hashtags: [
        {
          name,
          normalizedName,
          enforcement: 'advisory',
          ruleId: 'timeline-primary-hashtag',
        },
      ],
    },
  };
}
