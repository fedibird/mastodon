import { Set as ImmutableSet } from 'immutable';

// Effective ActivityPub audience target for a composer draft.
//
// This is addressing metadata. It is not a managed mention and must not be
// written into the status text.

// P11 permits an explicit Group audience only on public and unlisted posts.
export const ACTIVITYPUB_AUDIENCE_ALLOWED_VISIBILITIES = ImmutableSet(['public', 'unlisted']);

const present = value => value !== null && value !== undefined && value !== '';

export function composerActivityPubAudienceAccountId(composer) {
  if (!composer) {
    return null;
  }

  // Existing status edits keep the target already stored on the status.
  const statusId = composer.get('id');

  if (statusId !== null && statusId !== undefined) {
    return null;
  }

  // A scheduled draft carries its own saved target, even when the current
  // timeline context asks for a different one or for none.
  const scheduledStatusId = composer.get('scheduled_status_id');

  if (scheduledStatusId !== null && scheduledStatusId !== undefined) {
    return composer.get('draft_audience_account_id') || null;
  }

  return composer.getIn([
    'context',
    'protocol',
    'activityPub',
    'audience',
    'accountId',
  ], null) || null;
}

// Visibility choices that belong to the effective audience target.
// Existing status edits have none. A scheduled draft uses its retained
// target, not the timeline context. A new post uses the context constraint
// when that context names an audience.
export function composerActivityPubAudienceAllowedVisibilities(composer) {
  if (!composer) {
    return null;
  }

  const statusId = composer.get('id');

  if (present(statusId)) {
    return null;
  }

  const scheduledStatusId = composer.get('scheduled_status_id');

  if (present(scheduledStatusId)) {
    return present(composer.get('draft_audience_account_id'))
      ? ACTIVITYPUB_AUDIENCE_ALLOWED_VISIBILITIES
      : null;
  }

  const audienceAccountId = composer.getIn([
    'context',
    'protocol',
    'activityPub',
    'audience',
    'accountId',
  ], null);

  if (!present(audienceAccountId)) {
    return null;
  }

  return composer.getIn(['context', 'constraints', 'allowedVisibilities'], null);
}
