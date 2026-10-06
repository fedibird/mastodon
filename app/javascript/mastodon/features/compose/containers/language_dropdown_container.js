import { Map as ImmutableMap } from 'immutable';
import { connect } from 'react-redux';
import { createSelector } from 'reselect';

import { changeComposeLanguage } from 'mastodon/actions/compose';
import { targetComposerAction } from 'mastodon/actions/composer';
import { useLanguage } from 'mastodon/actions/languages';
import { selectComposer } from 'mastodon/selectors/composer';

import { withComposerId } from '../composer_id_context';
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

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  return {
    frequentlyUsedLanguages: getFrequentlyUsedLanguages(state),
    value: composer.get('language'),
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onChange (value) {
    dispatch(targetComposerAction(changeComposeLanguage(value), composerId));
  },

  onClose (value) {
    dispatch(useLanguage(value));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(LanguageDropdown));
