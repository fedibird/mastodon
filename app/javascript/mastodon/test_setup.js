import '@testing-library/jest-dom/extend-expect';
import IntlMessageFormat from 'intl-messageformat';
import IntlRelativeFormat from 'intl-relativeformat';

// react-intl v2 consults both legacy __localeData maps to decide whether an
// IntlProvider can render a locale. Some installed formatter versions expose
// neither that map nor __addLocaleData, even though formatting still works.
// Restore the locale registration contract in Jest ONLY; production is untouched.
[IntlMessageFormat, IntlRelativeFormat].forEach(Formatter => {
  if (!Formatter.__localeData) {
    Formatter.__localeData = Object.create(null);
  }

  // intl-messageformat v2 already provides a working (read-only)
  // __addLocaleData. Never replace it. Only polyfill a missing method,
  // which is the case for newer intl-relativeformat releases.
  if (typeof Formatter.__addLocaleData !== 'function') {
    Formatter.__addLocaleData = localeData => {
      const entries = Array.isArray(localeData) ? localeData : [localeData];

      entries.forEach(entry => {
        if (entry && entry.locale) {
          Formatter.__localeData[entry.locale] = entry;
        }
      });
    };
  }
});
