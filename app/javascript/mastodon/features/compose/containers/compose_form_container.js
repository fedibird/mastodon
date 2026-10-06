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
import { selectComposer } from '../../../selectors/composer';
import { injectIntl, defineMessages } from 'react-intl';

const messages = defineMessages({
  cancelEditConfirm: { id: 'confirmations.cancel_edit.confirm', defaultMessage: 'Discard changes' },
  cancelEditMessage: { id: 'confirmations.cancel_edit.message', defaultMessage: 'Canceling will discard the changes you are currently composing. Are you sure you want to proceed?' },
});

const mapStateToProps = state => {
  const composer = selectComposer(state);

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

const mapDispatchToProps = (dispatch, { intl }) => ({

  onChange (text) {
    dispatch(changeCompose(text));
  },

  onSubmit (router) {
    dispatch(submitComposeWithCheck(router, intl));
  },

  onClearSuggestions () {
    dispatch(clearComposeSuggestions());
  },

  onFetchSuggestions (token) {
    dispatch(fetchComposeSuggestions(token));
  },

  onSuggestionSelected (position, token, suggestion, path) {
    dispatch(selectComposeSuggestion(position, token, suggestion, path));
  },

  onChangeSpoilerText (checked) {
    dispatch(changeComposeSpoilerText(checked));
  },

  onPaste (files) {
    dispatch(uploadCompose(files));
  },

  onPickEmoji (position, data, needsSpace) {
    dispatch(insertEmojiCompose(position, data, needsSpace));
  },

  onCancelEdit () {
    dispatch((_, getState) => {
      const composer = selectComposer(getState());

      if (composer.get('dirty')) {
        dispatch(openModal('CONFIRM', {
          message: intl.formatMessage(messages.cancelEditMessage),
          confirm: intl.formatMessage(messages.cancelEditConfirm),
          onConfirm: () => dispatch(cancelEditCompose()),
        }));
      } else {
        dispatch(cancelEditCompose());
      }
    });
  },

});

export default injectIntl(connect(mapStateToProps, mapDispatchToProps)(ComposeForm));
