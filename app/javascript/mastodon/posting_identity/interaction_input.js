import { postingContextOutputSignature } from '../posting_context/materialize';

const field = value => {
  const text = value === null || value === undefined ? '' : String(value);

  return `${text.length}:${text}`;
};

// The snapshot is the text, content warning, visibility, sender, and
// target that the preflight will submit. A later edit no longer matches.
export function composerInteractionInputKey (composer) {
  if (!composer || !composer.get) {
    return '';
  }

  const spoilerText = composer.get('spoiler') ? (composer.get('spoiler_text') || '') : '';

  return [
    field(composer.getIn(['senderIdentity', 'id'])),
    field(Number(composer.getIn(['senderIdentity', 'changeEpoch'])) || 0),
    field(composer.get('in_reply_to')),
    field(composer.get('quote_from')),
    field(composer.get('privacy')),
    field(composer.get('text')),
    field(spoilerText),
    field(composer.get('posting_context_account_id')),
    field(composer.getIn(['context', 'key'])),
    field(composer.getIn(['context', 'source', 'revision'])),
    field(postingContextOutputSignature(composer)),
  ].join('|');
}

export function composerInteractionSpoilerText (composer) {
  if (!composer || !composer.get || !composer.get('spoiler')) {
    return '';
  }

  return composer.get('spoiler_text') || '';
}
