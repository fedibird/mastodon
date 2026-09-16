import { normalizeFilterResult } from '../normalizer';

describe('normalizeFilterResult', () => {
  it('replaces the nested filter entity with its ID', () => {
    expect(normalizeFilterResult({
      filter: { id: '1', title: 'spoiler', filter_action: 'warn' },
      keyword_matches: ['foo'],
    })).toEqual({
      filter: '1',
      keyword_matches: ['foo'],
    });
  });

  it('leaves an already-normalized filter ID unchanged', () => {
    expect(normalizeFilterResult({ filter: '1', keyword_matches: [] })).toEqual({
      filter: '1',
      keyword_matches: [],
    });
  });
});
