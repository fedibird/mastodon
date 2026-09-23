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
import { injectIntl, defineMessages } from 'react-intl';

const messages = defineMessages({
  cancelEditConfirm: { id: 'confirmations.cancel_edit.confirm', defaultMessage: 'Discard changes' },
  cancelEditMessage: { id: 'confirmations.cancel_edit.message', defaultMessage: 'Canceling will discard the changes you are currently composing. Are you sure you want to proceed?' },
});

const mapStateToProps = state => ({
  text: state.getIn(['compose', 'text']),
  suggestions: state.getIn(['compose', 'suggestions']),
  spoiler: state.getIn(['compose', 'spoiler']),
  spoilerText: state.getIn(['compose', 'spoiler_text']),
  privacy: state.getIn(['compose', 'privacy']),
  focusDate: state.getIn(['compose', 'focusDate']),
  caretPosition: state.getIn(['compose', 'caretPosition']),
  preselectDate: state.getIn(['compose', 'preselectDate']),
  isSubmitting: state.getIn(['compose', 'is_submitting']),
  isChangingUpload: state.getIn(['compose', 'is_changing_upload']),
  isUploading: state.getIn(['compose', 'is_uploading']),
  isCircleUnselected: !state.getIn(['compose', 'id']) && state.getIn(['compose', 'privacy']) === 'limited' && state.getIn(['compose', 'reply_status', 'visibility']) !== 'limited' && !state.getIn(['compose', 'circle_id']),
  showSearch: state.getIn(['search', 'submitted']) && !state.getIn(['search', 'hidden']),
  anyMedia: state.getIn(['compose', 'media_attachments']).size > 0,
  prohibitedVisibilities: state.getIn(['compose', 'prohibited_visibilities']),
  prohibitedWords: state.getIn(['compose', 'prohibited_words']),
  isScheduled: !!state.getIn(['compose', 'scheduled']),
  isScheduledStatusEditting: !!state.getIn(['compose', 'scheduled_status_id']),
  isEditing: !!state.getIn(['compose', 'id']),
});

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
      if (getState().getIn(['compose', 'dirty'])) {
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
