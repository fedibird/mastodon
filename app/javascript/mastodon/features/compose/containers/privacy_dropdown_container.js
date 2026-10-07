import { connect } from 'react-redux';
import PrivacyDropdown from '../components/privacy_dropdown';
import { changeComposeVisibility } from '../../../actions/compose';
import { openModal, closeModal } from '../../../actions/modal';
import { targetComposerAction } from '../../../actions/composer';
import { isUserTouching } from '../../../is_mobile';
import { selectComposer } from '../../../selectors/composer';
import { composerActivityPubAudienceAllowedVisibilities } from '../../../posting_context/protocol';
import { withComposerId } from '../composer_id_context';

const present = value => value !== null && value !== undefined;

const allowedVisibilitiesForComposer = (composer) => {
  const audienceAllowed = composerActivityPubAudienceAllowedVisibilities(composer);

  if (audienceAllowed !== null && audienceAllowed !== undefined) {
    return audienceAllowed;
  }

  // Scheduled edits do not adopt the timeline Posting Context.
  if (!present(composer.get('id')) && present(composer.get('scheduled_status_id'))) {
    return null;
  }

  return composer.getIn(['context', 'constraints', 'allowedVisibilities']);
};

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  return {
    value: composer.get('privacy'),
    prohibitedVisibilities: composer.get('prohibited_visibilities'),
    allowedVisibilities: allowedVisibilitiesForComposer(composer),
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onChange (value) {
    dispatch(targetComposerAction(changeComposeVisibility(value), composerId));
  },

  isUserTouching,
  onModalOpen: props => dispatch(openModal('ACTIONS', props)),
  onModalClose: () => dispatch(closeModal()),

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(PrivacyDropdown));
