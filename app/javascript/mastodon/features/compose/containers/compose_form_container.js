import { connect } from 'react-redux';
import ComposeForm from '../components/compose_form';
import {
  changeCompose,
  submitComposeWithCheck,
  clearComposeSuggestions,
  fetchComposeSuggestions,
  selectComposeSuggestion,
  changeComposeSpoilerText,
  insertEmojiCompose,
  uploadCompose,
  cancelEditCompose,
} from '../../../actions/compose';
import { openModal } from '../../../actions/modal';
import { targetComposerAction } from '../../../actions/composer';
import { selectComposer } from '../../../selectors/composer';
import { PRIMARY_COMPOSER_ID } from '../../../utils/composer';
import { withComposerId } from '../composer_id_context';
import { injectIntl, defineMessages } from 'react-intl';

const messages = defineMessages({
  cancelEditConfirm: { id: 'confirmations.cancel_edit.confirm', defaultMessage: 'Discard changes' },
  cancelEditMessage: { id: 'confirmations.cancel_edit.message', defaultMessage: 'Canceling will discard the changes you are currently composing. Are you sure you want to proceed?' },
});

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  return {
    text: composer.get('text'),
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
  };
};

const mapDispatchToProps = (dispatch, { intl, composerId }) => ({

  onChange (text) {
    dispatch(targetComposerAction(changeCompose(text), composerId));
  },

  onSubmit (router) {
    if (composerId === PRIMARY_COMPOSER_ID) {
      dispatch(submitComposeWithCheck(router, intl));
    }
  },

  onClearSuggestions () {
    if (composerId === PRIMARY_COMPOSER_ID) {
      dispatch(clearComposeSuggestions());
    }
  },

  onFetchSuggestions (token) {
    if (composerId === PRIMARY_COMPOSER_ID) {
      dispatch(fetchComposeSuggestions(token));
    }
  },

  onSuggestionSelected (position, token, suggestion, path) {
    if (composerId === PRIMARY_COMPOSER_ID) {
      dispatch(selectComposeSuggestion(position, token, suggestion, path));
    }
  },

  onChangeSpoilerText (checked) {
    dispatch(targetComposerAction(changeComposeSpoilerText(checked), composerId));
  },

  onPaste (files) {
    if (composerId === PRIMARY_COMPOSER_ID) {
      dispatch(uploadCompose(files));
    }
  },

  onPickEmoji (position, data, needsSpace) {
    dispatch(targetComposerAction(insertEmojiCompose(position, data, needsSpace), composerId));
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

export default withComposerId(injectIntl(connect(mapStateToProps, mapDispatchToProps)(ComposeForm)));
