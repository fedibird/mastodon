// Effective ActivityPub audience target for a composer draft.
//
// This is addressing metadata. It is not a managed mention and must not be
// written into the status text.

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
