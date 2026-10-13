import { connect } from 'react-redux';
import SearchabilityIndicator from '../components/searchability_indicator';
import { resetComposeSearchability } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { selectComposer } from '../../../selectors/composer';
import { effectiveSearchability } from '../../../utils/searchability';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const value = composer.get('searchability');
  const effective = effectiveSearchability(composer.get('privacy'), composer.get('default_searchability'));

  return {
    changed: Boolean(value) && value !== effective,
    value,
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({
  onReset () {
    dispatch(targetComposerAction(resetComposeSearchability(), composerId));
  },
});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(SearchabilityIndicator));
