import { searchabilityCap, searchabilityIsChanged } from '../searchability';

describe('searchabilityIsChanged', () => {
  it('ignores legacy privacy restore points when the effective value is unchanged', () => {
    expect(searchabilityIsChanged({
      searchability: 'private',
      privacy: 'private',
      defaultSearchability: 'private',
      privacyBeforeSearchability: 'direct',
    })).toBe(false);
  });

  it('is unchanged when the value matches the effective default and nothing can be restored', () => {
    expect(searchabilityIsChanged({
      searchability: 'direct',
      privacy: 'direct',
      defaultSearchability: 'private',
      privacyBeforeSearchability: null,
    })).toBe(false);
  });

  it('is changed when the selected value differs from the effective default', () => {
    expect(searchabilityIsChanged({
      searchability: 'public',
      privacy: 'public',
      defaultSearchability: 'private',
      privacyBeforeSearchability: null,
    })).toBe(true);
  });
});

// Composer exposes three search choices; narrower server enum values map to direct.
describe('server search visibility cap', () => {
  const visibilities = ['public', 'unlisted', 'private', 'mutual', 'limited', 'direct', 'personal'];
  const cases = visibilities.flatMap(privacy => visibilities.map(desired => [privacy, desired]));

  it.each(cases)('caps %s / %s consistently with the server', (privacy, desired) => {
    let expected = 'private';

    if (!['public', 'unlisted', 'private'].includes(privacy) || !['public', 'unlisted', 'private'].includes(desired)) {
      expected = 'direct';
    } else if (privacy === 'public' && desired === 'public') {
      expected = 'public';
    }

    expect(searchabilityCap(privacy, desired)).toBe(expected);
  });
});
