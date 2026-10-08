import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { materializeManagedHashtags, normalizeManagedHashtagName } from './managed_hashtags';
import { materializeManagedMentions, normalizeManagedMentionAcct } from './managed_mentions';

export function isExistingPostEdit(composer) {
  if (!composer) {
    return false;
  }

  const id = composer.get('id');
  const scheduledStatusId = composer.get('scheduled_status_id');

  return (id !== null && id !== undefined) || (scheduledStatusId !== null && scheduledStatusId !== undefined);
}

const activeManagedMentions = composer => {
  const mentions = composer.getIn(['context', 'managed', 'mentions']);
  const active = [];

  if (mentions && mentions.forEach) {
    mentions.forEach(mention => {
      if (mention.get('enforcement') === 'required' && mention.get('acct')) {
        active.push({
          accountId: mention.get('accountId'),
          acct: mention.get('acct'),
        });
      }
    });
  }

  return active;
};

const tagRecord = (tag, origin) => {
  const name = tag && tag.get ? tag.get('name') : tag && tag.name;
  const normalizedName = normalizeManagedHashtagName((tag && tag.get ? (tag.get('normalizedName') || tag.get('name')) : (tag && (tag.normalizedName || tag.name))) || '');

  if (!normalizedName) {
    return null;
  }

  return {
    name: String(name || normalizedName).replace(/^[#＃]+/u, ''),
    normalizedName,
    enforcement: (tag && tag.get ? tag.get('enforcement') : tag && tag.enforcement) || 'advisory',
    origin,
  };
};

const rememberTag = (groups, record) => {
  if (!record) {
    return;
  }

  if (!groups.has(record.normalizedName)) {
    groups.set(record.normalizedName, []);
  }

  groups.get(record.normalizedName).push(record);
};

const collectTagGroups = composer => {
  const groups = new Map();
  const contextTags = composer.getIn(['context', 'managed', 'hashtags']);

  if (contextTags && contextTags.forEach) {
    contextTags.forEach(tag => rememberTag(groups, tagRecord(tag, 'context')));
  }

  const snapshot = composer.getIn(['userPostingStyle', 'snapshot']);
  const selectedId = composer.getIn(['userPostingStyle', 'selectedId']);

  if (snapshot && selectedId) {
    const styleTags = snapshot.getIn(['managed', 'hashtags']);

    if (styleTags && styleTags.forEach) {
      styleTags.forEach(tag => rememberTag(groups, tagRecord(tag, 'style')));
    }

    if (snapshot.getIn(['target', 'kind']) === 'hashtag' && composer.getIn(['userPostingStyle', 'destinationStatus']) === 'ready') {
      const hashtag = snapshot.getIn(['target', 'hashtag']);

      rememberTag(groups, tagRecord(ImmutableMap({
        name: hashtag,
        normalizedName: hashtag,
        enforcement: 'advisory',
      }), 'destination'));
    }
  }

  return groups;
};

const originActive = (record, composer) => {
  if (record.enforcement === 'required') {
    return true;
  }

  if (record.origin === 'style' || record.origin === 'destination') {
    const suppressed = composer.getIn(['userPostingStyle', 'suppressions']);

    return !suppressed || !suppressed.includes(`${record.origin}:${record.normalizedName}`);
  }

  const suppressed = composer.getIn(['context', 'suppressions', 'hashtags']);

  return !suppressed || !suppressed.includes(record.normalizedName);
};

const preferredRecord = records => (
  records.find(record => record.enforcement === 'required')
  || records.find(record => record.origin === 'destination')
  || records.find(record => record.origin === 'style')
  || records[0]
);

const activeManagedHashtags = composer => {
  const active = [];

  collectTagGroups(composer).forEach(records => {
    const live = records.filter(record => originActive(record, composer));

    if (live.length === 0) {
      return;
    }

    const chosen = preferredRecord(live);

    active.push({
      name: chosen.name,
      normalizedName: chosen.normalizedName,
    });
  });

  return active;
};

export function activeManagedHashtagSignature(composer) {
  if (!composer) {
    return '';
  }

  return activeManagedHashtags(composer).map(tag => tag.normalizedName).sort().join('\0');
}

export function postingContextOutputSignature(composer) {
  if (!composer) {
    return '';
  }

  const hashtagPart = activeManagedHashtagSignature(composer);
  const mentions = composer.getIn(['context', 'managed', 'mentions']);
  const mentionPart = mentions && mentions.filter ? mentions
    .filter(mention => mention.get('enforcement') === 'required' && mention.get('acct'))
    .map(mention => `${mention.get('accountId')}:${normalizeManagedMentionAcct(mention.get('acct'))}`)
    .sort()
    .join('\0') : '';
  const audienceAccountId = composer.getIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'], null) || '';

  return [hashtagPart, mentionPart, audienceAccountId].filter(Boolean).join('\n');
}

export function styleHashtagChips(composer) {
  const chips = [];
  const snapshot = composer && composer.getIn(['userPostingStyle', 'snapshot']);
  const selectedId = composer && composer.getIn(['userPostingStyle', 'selectedId']);

  if (!snapshot || !selectedId || isExistingPostEdit(composer)) {
    return ImmutableList(chips);
  }

  const suppressed = composer.getIn(['userPostingStyle', 'suppressions']);
  const pushChip = (name, origin) => {
    const normalizedName = normalizeManagedHashtagName(name);

    if (!normalizedName || chips.some(chip => chip.origin === origin && chip.normalizedName === normalizedName)) {
      return;
    }

    chips.push({
      name: String(name || normalizedName).replace(/^[#＃]+/u, ''),
      normalizedName,
      enforcement: 'advisory',
      origin,
      suppressed: Boolean(suppressed && suppressed.includes(`${origin}:${normalizedName}`)),
    });
  };

  const styleTags = snapshot.getIn(['managed', 'hashtags']);

  if (styleTags && styleTags.forEach) {
    styleTags.forEach(tag => pushChip(tag.get('name'), 'style'));
  }

  if (snapshot.getIn(['target', 'kind']) === 'hashtag' && composer.getIn(['userPostingStyle', 'destinationStatus']) === 'ready') {
    pushChip(snapshot.getIn(['target', 'hashtag']), 'destination');
  }

  return ImmutableList(chips.map(chip => ImmutableMap(chip)));
}

export function materializeComposerText(composer) {
  if (!composer) {
    return '';
  }

  const text = composer.get('text', '') || '';

  if (isExistingPostEdit(composer)) {
    return text;
  }

  return materializeManagedHashtags(materializeManagedMentions(text, activeManagedMentions(composer)), activeManagedHashtags(composer));
}
