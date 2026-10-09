import { isAdministrator, new_features_policy as newFeaturesPolicy } from 'mastodon/initial_state';

// Mix stays limited to administrators and accounts that opted into beta
// testing. Viewing a source still uses that account's existing permissions.
export const isMixEnabled = (options = {}) => {
  const administrator = options.isAdministrator !== undefined ? options.isAdministrator : isAdministrator;
  const policy = options.newFeaturesPolicy !== undefined ? options.newFeaturesPolicy : newFeaturesPolicy;

  return administrator === true || policy === 'tester';
};
