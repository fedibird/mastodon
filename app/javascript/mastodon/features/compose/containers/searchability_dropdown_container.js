import { connect } from 'react-redux';
import SearchabilityDropdown from '../components/searchability_dropdown';
import { changeComposeSearchability } from '../../../actions/compose';
import { openModal, closeModal } from '../../../actions/modal';
import { targetComposerAction } from '../../../actions/composer';
import { scheduleComposerInteractionCheck } from '../../../actions/posting_identities';
import { isUserTouching } from '../../../is_mobile';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  return {
    value: composer.get('searchability'),
    privacy: composer.get('privacy'),
    prohibitedVisibilities: composer.get('prohibited_visibilities'),
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onChange (value) {
    dispatch(targetComposerAction(changeComposeSearchability(value), composerId));
    dispatch(scheduleComposerInteractionCheck(composerId));
  },

  isUserTouching,
  onModalOpen: props => dispatch(openModal('ACTIONS', props)),
  onModalClose: () => dispatch(closeModal()),

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(SearchabilityDropdown));
