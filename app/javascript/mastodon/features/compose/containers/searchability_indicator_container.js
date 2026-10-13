import { connect } from 'react-redux';
import SearchabilityIndicator from '../components/searchability_indicator';
import { changeComposeSearchability } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const value = composer.get('searchability');
  const fallback = composer.get('default_searchability');

  return {
    changed: Boolean(value) && Boolean(fallback) && value !== fallback,
    value,
    fallback,
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({
  onReset (fallback) {
    dispatch(targetComposerAction(changeComposeSearchability(fallback), composerId));
  },
});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(SearchabilityIndicator));
