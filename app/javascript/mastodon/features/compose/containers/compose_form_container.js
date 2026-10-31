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
  changeComposeSpoilerness,
  insertEmojiCompose,
  uploadToComposer,
  cancelEditCompose,
} from '../../../actions/compose';
import { openModal } from '../../../actions/modal';
import { acceptComposerSurface, targetComposerAction } from '../../../actions/composer';
import { scheduleComposerInteractionCheck } from '../../../actions/posting_identities';
import { selectComposerEffectiveCreateCapability } from '../../../posting_context/create_capability';
import { materializeComposerText } from '../../../posting_context/materialize';
import { selectComposer } from '../../../selectors/composer';
import { selectComposerCanSendAsIdentity, selectComposerCanUploadAsIdentity } from '../../../selectors/posting_identities';
import { withComposerId } from '../composer_id_context';
import SenderIdentityContainer from './sender_identity_container';
import UserPostingStyleController from './user_posting_style_controller';
import UserPostingStylePickerContainer from './user_posting_style_picker_container';
import ComposerContextDetails from '../components/composer_context_details';
import { injectIntl, defineMessages } from 'react-intl';
import { composerRedraftNotice, confirmDiscardUnconfirmedRedraft, retryRedraftMedia } from '../../../actions/redraft_media';
import { composerToolbar, isAdministrator, showComposerPostingStyleSelector } from '../../../initial_state';
import { postingAccountControlAvailable } from '../composer_toolbar';

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
    canUploadMedia: selectComposerCanUploadAsIdentity(state, composerId).canUpload,
    uploadBlockReason: selectComposerCanUploadAsIdentity(state, composerId).reason,
    sendBlockReason: selectComposerCanSendAsIdentity(state, composerId).reason,
    capabilityReason: capability.reason,
    hasPoll: Boolean(composer.get('poll')),
    datetimeOpen: Boolean(composer.get('datetime_form')),
    hasExpiry: Boolean(composer.get('expires')),
    sensitive: composer.get('sensitive') === true,
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
    isProcessing: composer.get('is_processing'),
    pendingMedia: composer.get('pending_media_attachments') || 0,
    isCircleUnselected: !composer.get('id') && composer.get('privacy') === 'limited' && composer.getIn(['reply_status', 'visibility']) !== 'limited' && !composer.get('circle_id'),
    showSearch: state.getIn(['search', 'submitted']) && !state.getIn(['search', 'hidden']),
    anyMedia: composer.get('media_attachments').size > 0,
    searchability: composer.get('searchability'),
    defaultSearchability: composer.get('default_searchability'),
    privacyBeforeSearchability: composer.get('privacy_before_searchability'),
    prohibitedVisibilities: composer.get('prohibited_visibilities'),
    prohibitedWords: composer.get('prohibited_words'),
    isScheduled: !!composer.get('scheduled'),
    isScheduledStatusEditting: !!composer.get('scheduled_status_id'),
    isEditing: !!composer.get('id'),
    lang: composer.get('language'),
    showPostingAccount: postingAccountControlAvailable({
      catalog: state.getIn(['postingIdentities', 'identities']),
      status: state.getIn(['postingIdentities', 'status'], 'idle'),
      selectedId: composer.getIn(['senderIdentity', 'id']),
      canLink: isAdministrator,
    }),
    surfaceMismatch: composer.get('surfaceMismatch') === true,
    redraftNotice: composerRedraftNotice(composer),
  };
};

const mapDispatchToProps = (dispatch, { intl, composerId }) => ({

  onChange (text) {
    dispatch(targetComposerAction(changeCompose(text), composerId));
    dispatch(scheduleComposerInteractionCheck(composerId));
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
    dispatch(scheduleComposerInteractionCheck(composerId));
  },

  onChangeSpoilerText (checked) {
    dispatch(targetComposerAction(changeComposeSpoilerText(checked), composerId));
    dispatch(scheduleComposerInteractionCheck(composerId));
  },

  onToggleSpoilerness () {
    dispatch(targetComposerAction(changeComposeSpoilerness(), composerId));
    dispatch(scheduleComposerInteractionCheck(composerId));
  },

  onPaste (files) {
    dispatch(uploadToComposer(composerId, files));
  },

  onPickEmoji (position, data, needsSpace) {
    dispatch(targetComposerAction(insertEmojiCompose(position, data, needsSpace), composerId));
    dispatch(scheduleComposerInteractionCheck(composerId));
  },

  onAcceptSurface () {
    dispatch(acceptComposerSurface(composerId));
  },

  onRetryRedraft () {
    dispatch(retryRedraftMedia(composerId));
  },

  onDiscardUnconfirmedRedraft () {
    dispatch(confirmDiscardUnconfirmedRedraft(composerId, intl));
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

const styleControlsAvailable = isAdministrator && showComposerPostingStyleSelector !== false;

const ComposeFormWithPostingStyles = props => (
  <ConnectedComposeForm
    {...props}
    styleController={<UserPostingStyleController />}
    stylePicker={<UserPostingStylePickerContainer header contextDetails={styleControlsAvailable ? <ComposerContextDetails /> : null} />}
    overflowContext={styleControlsAvailable ? null : <ComposerContextDetails />}
    composerToolbar={composerToolbar}
    senderIdentity={<SenderIdentityContainer />}
  />
);

ComposeFormWithPostingStyles.propTypes = {
  composerId: PropTypes.string,
};

export default withComposerId(ComposeFormWithPostingStyles);
