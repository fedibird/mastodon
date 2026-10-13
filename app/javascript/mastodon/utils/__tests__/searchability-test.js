import { searchabilityIsChanged } from '../searchability';

describe('searchabilityIsChanged', () => {
  it('stays changed while a privacy restore point remains', () => {
    expect(searchabilityIsChanged({
      searchability: 'private',
      privacy: 'private',
      defaultSearchability: 'private',
      privacyBeforeSearchability: 'direct',
    })).toBe(true);
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
