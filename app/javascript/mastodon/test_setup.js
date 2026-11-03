import '@testing-library/jest-dom/extend-expect';
import IntlRelativeFormat from 'intl-relativeformat';

// react-intl v2 registers legacy locale data through this static method, but
// the installed intl-relativeformat v6 uses native Intl.RelativeTimeFormat and
// no longer exposes it. Keep the compatibility shim scoped to Jest rather than
// changing any runtime translation/locale behavior.
if (typeof IntlRelativeFormat.__addLocaleData !== 'function') {
  IntlRelativeFormat.__addLocaleData = () => {};
}
