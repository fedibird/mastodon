export const EMOJI_MUTES_IMPORT = 'EMOJI_MUTES_IMPORT';
export const EMOJI_MUTES_REVISION = 'EMOJI_MUTES_REVISION';

export function importEmojiMutes(revision, rules) {
  return {
    type: EMOJI_MUTES_IMPORT,
    revision: revision === null || revision === undefined ? null : String(revision),
    rules: rules || [],
  };
}

export function importEmojiMutesRevision(revision) {
  return {
    type: EMOJI_MUTES_REVISION,
    revision: revision === null || revision === undefined ? null : String(revision),
  };
}
