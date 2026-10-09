import { isMixEnabled } from '../availability';

describe('mix availability', () => {
  it('enables the feature for administrators and beta testers', () => {
    expect(isMixEnabled({ isAdministrator: true, newFeaturesPolicy: 'default' })).toBe(true);
    expect(isMixEnabled({ isAdministrator: true, newFeaturesPolicy: 'conservative' })).toBe(true);
    expect(isMixEnabled({ isAdministrator: false, newFeaturesPolicy: 'tester' })).toBe(true);
    expect(isMixEnabled({ isAdministrator: false, newFeaturesPolicy: 'default' })).toBe(false);
    expect(isMixEnabled({ isAdministrator: false, newFeaturesPolicy: 'conservative' })).toBe(false);
    expect(isMixEnabled({ isStaff: true, isAdministrator: false, newFeaturesPolicy: 'default' })).toBe(false);
  });
});
