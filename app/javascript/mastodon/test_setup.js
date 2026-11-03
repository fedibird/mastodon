import '@testing-library/jest-dom/extend-expect';
import IntlRelativeFormat from 'intl-relativeformat';

// react-intl v2 checks the old static locale registry, while the installed
// intl-relativeformat v6 has neither the registry nor __addLocaleData.
// Reconstruct only locale registration in Jest; runtime formatting is untouched.
if (typeof IntlRelativeFormat.__addLocaleData !== 'function') {
  IntlRelativeFormat.__localeData = Object.create(null);
  IntlRelativeFormat.__addLocaleData = data => {
    const entries = Array.isArray(data) ? data : [data];

    entries.forEach(entry => {
      if (entry && entry.locale) {
        IntlRelativeFormat.__localeData[entry.locale] = entry;
      }
    });
  };
}
