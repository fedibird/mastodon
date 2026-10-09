import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import ComposeForm from '../components/compose_form';
import {
  changeCompose,
  submitComposerWithCheck,
  clearComposerSuggestions,
  fetchComposerSuggestions,
  selectComposerSuggestion,
  changeComposeSpoilerText,
  insertEmojiCompose,
  uploadToComposer,
  cancelEditCompose,
} from '../../../actions/compose';
import { openModal } from '../../../actions/modal';
import { acceptComposerSurface, targetComposerAction } from '../../../actions/composer';
import { selectComposerEffectiveCreateCapability } from '../../../posting_context/create_capability';
import { materializeComposerText } from '../../../posting_context/materialize';
import { selectComposer } from '../../../selectors/composer';
import { selectComposerCanSendAsIdentity } from '../../../selectors/posting_identities';
import { withComposerId } from '../composer_id_context';
import SenderIdentityContainer from './sender_identity_container';
import UserPostingStyleController from './user_posting_style_controller';
import UserPostingStylePickerContainer from './user_posting_style_picker_container';
import { injectIntl, defineMessages } from 'react-intl';

const messages = defineMessages({
  cancelEditConfirm: { id: 'confirmations.cancel_edit.confirm', defaultMessage: 'Discard changes' },
  cancelEditMessage: { id: 'confirmations.cancel_edit.message', defaultMessage: 'Canceling will discard the changes you are currently composing. Are you sure you want to proceed?' },
});

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  const capability = selectComposerEffectiveCreateCapability(state, composerId);

  return {
    text: composer.get('text'),
    effectiveText: materializeComposerText(composer),
    contextCompliant: capability.compliance.valid,
    canAttempt: capability.canAttempt,
    canSendAsIdentity: selectComposerCanSendAsIdentity(state, composerId).canSend,
    capabilityReason: capability.reason,
    suggestions: composer.get('suggestions'),
    spoiler: composer.get('spoiler'),
    spoilerText: composer.get('spoiler_text'),
    privacy: composer.get('privacy'),
    focusDate: composer.get('focusDate'),
    caretPosition: composer.get('caretPosition'),
    preselectDate: composer.get('preselectDate'),
    isSubmitting: composer.get('is_submitting'),
    isChangingUpload: composer.get('is_changing_upload'),
    isUploading: composer.get('is_uploading'),
    isCircleUnselected: !composer.get('id') && composer.get('privacy') === 'limited' && composer.getIn(['reply_status', 'visibility']) !== 'limited' && !composer.get('circle_id'),
    showSearch: state.getIn(['search', 'submitted']) && !state.getIn(['search', 'hidden']),
    anyMedia: composer.get('media_attachments').size > 0,
    prohibitedVisibilities: composer.get('prohibited_visibilities'),
    prohibitedWords: composer.get('prohibited_words'),
    isScheduled: !!composer.get('scheduled'),
    isScheduledStatusEditting: !!composer.get('scheduled_status_id'),
    isEditing: !!composer.get('id'),
    lang: composer.get('language'),
    surfaceMismatch: composer.get('surfaceMismatch') === true,
  };
};

const mapDispatchToProps = (dispatch, { intl, composerId }) => ({

  onChange (text) {
    dispatch(targetComposerAction(changeCompose(text), composerId));
  },

  onSubmit (router) {
    dispatch(submitComposerWithCheck(composerId, router, intl));
  },

  onClearSuggestions () {
    dispatch(clearComposerSuggestions(composerId));
  },

  onFetchSuggestions (token) {
    dispatch(fetchComposerSuggestions(composerId, token));
  },

  onSuggestionSelected (position, token, suggestion, path) {
    dispatch(selectComposerSuggestion(composerId, position, token, suggestion, path));
  },

  onChangeSpoilerText (checked) {
    dispatch(targetComposerAction(changeComposeSpoilerText(checked), composerId));
  },

  onPaste (files) {
    dispatch(uploadToComposer(composerId, files));
  },

  onPickEmoji (position, data, needsSpace) {
    dispatch(targetComposerAction(insertEmojiCompose(position, data, needsSpace), composerId));
  },

  onAcceptSurface () {
    dispatch(acceptComposerSurface(composerId));
  },

  onCancelEdit () {
    dispatch((_, getState) => {
      const composer = selectComposer(getState(), composerId);
      const cancel = () => dispatch(targetComposerAction(cancelEditCompose(), composerId));

      if (composer.get('dirty')) {
        dispatch(openModal('CONFIRM', {
          message: intl.formatMessage(messages.cancelEditMessage),
          confirm: intl.formatMessage(messages.cancelEditConfirm),
          onConfirm: cancel,
        }));
      } else {
        cancel();
      }
    });
  },

});

const ConnectedComposeForm = injectIntl(connect(mapStateToProps, mapDispatchToProps)(ComposeForm));

const ComposeFormWithPostingStyles = props => (
  <ConnectedComposeForm
    {...props}
    styleController={<UserPostingStyleController />}
    stylePicker={<UserPostingStylePickerContainer />}
    senderIdentity={<SenderIdentityContainer />}
  />
);

ComposeFormWithPostingStyles.propTypes = {
  composerId: PropTypes.string,
};

export default withComposerId(ComposeFormWithPostingStyles);
