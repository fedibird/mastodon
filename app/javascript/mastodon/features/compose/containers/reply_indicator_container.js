import { connect } from 'react-redux';
import { cancelReplyCompose } from '../../../actions/compose';
import { openModal } from '../../../actions/modal';
import { targetComposerAction } from '../../../actions/composer';
import { makeGetStatus } from '../../../selectors';
import { selectComposer } from '../../../selectors/composer';
import ReplyIndicator from '../components/reply_indicator';
import { withComposerId } from '../composer_id_context';
import { defineMessages, injectIntl } from 'react-intl';

const messages = defineMessages({
  cancelReplyConfirm: { id: 'confirmations.cancel_reply.confirm', defaultMessage: 'Canceling reply' },
  cancelReplyMessage: { id: 'confirmations.cancel_reply.message', defaultMessage: 'Canceling a reply will erase the message you are currently composing. Are you sure you want to proceed?' },
});

const makeMapStateToProps = () => {
  const getStatus = makeGetStatus();

  const mapStateToProps = (state, { composerId }) => {
    const composer = selectComposer(state, composerId);

    return {
      status: getStatus(state, { id: composer.get('in_reply_to') }),
      isScheduledStatusEditting: !!composer.get('scheduled_status_id'),
      isEditing: !!composer.get('id'),
    };
  };

  return mapStateToProps;
};

const mapDispatchToProps = (dispatch, { intl, composerId }) => ({

  onCancel () {
    dispatch((_, getState) => {
      const composer = selectComposer(getState(), composerId);
      const cancel = () => dispatch(targetComposerAction(cancelReplyCompose(), composerId));

      if (composer.get('text').trim().length !== 0 && composer.get('dirty')) {
        dispatch(openModal('CONFIRM', {
          message: intl.formatMessage(messages.cancelReplyMessage),
          confirm: intl.formatMessage(messages.cancelReplyConfirm),
          onConfirm: cancel,
        }));
      } else {
        cancel();
      }
    });
  },

});

export default withComposerId(injectIntl(connect(makeMapStateToProps, mapDispatchToProps)(ReplyIndicator)));
