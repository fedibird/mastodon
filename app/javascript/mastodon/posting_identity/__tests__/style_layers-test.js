import { POSTING_STYLE_LAYERS, resolvePostingStyleField } from '../style_layers';

describe('posting style layers', () => {
  const sources = {
    identity: { required: { sensitive: true } },
    postingContext: { required: { privacy: 'public' } },
    userPostingContext: { privacy: 'private', language: 'ja' },
    manual: { privacy: 'direct', language: 'en' },
  };

  it('applies identity, destination, saved style, then manual edits', () => {
    expect(POSTING_STYLE_LAYERS).toEqual([
      'identity',
      'posting_context',
      'user_posting_context',
      'manual',
    ]);
  });

  it('does not let a saved style or a manual edit replace a required sender or destination value', () => {
    expect(resolvePostingStyleField('sensitive', sources)).toEqual({ value: true, layer: 'identity' });
    expect(resolvePostingStyleField('privacy', sources)).toEqual({ value: 'public', layer: 'posting_context' });
    expect(resolvePostingStyleField('language', sources)).toEqual({ value: 'en', layer: 'manual' });
    expect(resolvePostingStyleField('language', { ...sources, manual: {} })).toEqual({
      value: 'ja',
      layer: 'user_posting_context',
    });
  });
});
