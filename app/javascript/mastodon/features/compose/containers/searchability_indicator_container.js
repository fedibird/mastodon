import { connect } from 'react-redux';
import SearchabilityIndicator from '../components/searchability_indicator';
import { resetComposeSearchability } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { scheduleComposerInteractionCheck } from '../../../actions/posting_identities';
import { selectComposer } from '../../../selectors/composer';
import { searchabilityIsChanged } from '../../../utils/searchability';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const value = composer.get('searchability');

  return {
    changed: searchabilityIsChanged({
      searchability: value,
      privacy: composer.get('privacy'),
      defaultSearchability: composer.get('default_searchability'),
      privacyBeforeSearchability: composer.get('privacy_before_searchability'),
    }),
    value,
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({
  onReset () {
    dispatch(targetComposerAction(resetComposeSearchability(), composerId));
    dispatch(scheduleComposerInteractionCheck(composerId));
  },
});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(SearchabilityIndicator));
