import { fromJS } from 'immutable';

import { displayedFeaturedTags } from '../featured_tags';

describe('featured account tag choices', () => {
  const saved = fromJS([
    { id: 'one', name: 'first', statuses_count: 12 },
    { id: 'two', name: 'second', statuses_count: 4 },
  ]);

  it('appends a non-featured tag temporarily without changing the saved list', () => {
    const shown = displayedFeaturedTags(saved, 'OtherTag');
    expect(shown.map(item => item.get('name')).toArray()).toEqual(['first', 'second', 'OtherTag']);
    expect(shown.last().get('temporary')).toBe(true);
    expect(shown.last().get('statuses_count')).toBeUndefined();
    expect(saved.size).toBe(2);
  });

  it('does not duplicate a registered tag, even with case differences', () => {
    const shown = displayedFeaturedTags(saved, 'FIRST');
    expect(shown).toBe(saved);
  });

  it('shows a temporary tag even if no featured tags exist', () => {
    expect(displayedFeaturedTags(fromJS([]), '#visitor').first().get('name')).toBe('visitor');
    expect(displayedFeaturedTags(fromJS([]), null).size).toBe(0);
  });
});
