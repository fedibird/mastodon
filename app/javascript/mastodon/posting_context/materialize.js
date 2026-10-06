import { materializeManagedHashtags } from './managed_hashtags';
import { materializeManagedMentions } from './managed_mentions';

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

const activeManagedHashtags = composer => {
  const hashtags = composer.getIn(['context', 'managed', 'hashtags']);
  const suppressed = composer.getIn(['context', 'suppressions', 'hashtags']);
  const active = [];

  if (hashtags && hashtags.forEach) {
    hashtags.forEach(tag => {
      const normalizedName = tag.get('normalizedName');

      if (!suppressed || !suppressed.includes(normalizedName)) {
        active.push({
          name: tag.get('name'),
          normalizedName,
        });
      }
    });
  }

  return active;
};

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
