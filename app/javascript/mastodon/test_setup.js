import '@testing-library/jest-dom/extend-expect';
import IntlMessageFormat from 'intl-messageformat';
import IntlRelativeFormat from 'intl-relativeformat';

// react-intl v2 checks BOTH formatters' __localeData__ registries (note the
// TWO trailing underscores). intl-relativeformat v6 no longer exposes the
// legacy API expected by react-intl v2. Restore it in Jest only.
// Existing methods (including read-only __addLocaleData on the v2 message
// formatter) must not be replaced. Production locale handling is unchanged.
[IntlMessageFormat, IntlRelativeFormat].forEach(Formatter => {
  if (!Formatter.__localeData__) {
    Formatter.__localeData__ = Object.create(null);
  }

  if (typeof Formatter.__addLocaleData !== 'function') {
    Formatter.__addLocaleData = localeData => {
      const entries = Array.isArray(localeData) ? localeData : [localeData];

      entries.forEach(entry => {
        if (entry && entry.locale) {
          Formatter.__localeData__[entry.locale.toLowerCase()] = entry;
        }
      });
    };
  }
});
