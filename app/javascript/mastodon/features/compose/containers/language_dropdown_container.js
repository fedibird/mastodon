import { Map as ImmutableMap } from 'immutable';
import { connect } from 'react-redux';
import { createSelector } from 'reselect';

import { changeComposeLanguage } from 'mastodon/actions/compose';
import { useLanguage } from 'mastodon/actions/languages';
import { selectComposer } from 'mastodon/selectors/composer';

import LanguageDropdown from '../components/language_dropdown';

const emptyLanguageCounters = ImmutableMap();

const getFrequentlyUsedLanguages = createSelector([
  state => state.getIn(['settings', 'frequentlyUsedLanguages'], emptyLanguageCounters),
], languageCounters => (
  languageCounters.keySeq()
    .sort((a, b) => languageCounters.get(a) - languageCounters.get(b))
    .reverse()
    .toArray()
));

const mapStateToProps = state => {
  const composer = selectComposer(state);

  return {
    frequentlyUsedLanguages: getFrequentlyUsedLanguages(state),
    value: composer.get('language'),
  };
};

const mapDispatchToProps = dispatch => ({

  onChange (value) {
    dispatch(changeComposeLanguage(value));
  },

  onClose (value) {
    dispatch(useLanguage(value));
  },

});

export default connect(mapStateToProps, mapDispatchToProps)(LanguageDropdown);
