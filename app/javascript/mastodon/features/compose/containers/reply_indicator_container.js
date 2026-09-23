import { connect } from 'react-redux';
import { cancelReplyCompose } from '../../../actions/compose';
import { openModal } from '../../../actions/modal';
import { makeGetStatus } from '../../../selectors';
import ReplyIndicator from '../components/reply_indicator';
import { defineMessages, injectIntl } from 'react-intl';

const messages = defineMessages({
  cancelReplyConfirm: { id: 'confirmations.cancel_reply.confirm', defaultMessage: 'Canceling reply' },
  cancelReplyMessage: { id: 'confirmations.cancel_reply.message', defaultMessage: 'Canceling a reply will erase the message you are currently composing. Are you sure you want to proceed?' },
});

const makeMapStateToProps = () => {
  const getStatus = makeGetStatus();

  const mapStateToProps = state => ({
    status: getStatus(state, { id: state.getIn(['compose', 'in_reply_to']) }),
    isScheduledStatusEditting: !!state.getIn(['compose', 'scheduled_status_id']),
    isEditing: !!state.getIn(['compose', 'id']),
  });

  return mapStateToProps;
};

const mapDispatchToProps = (dispatch, { intl }) => ({

  onCancel () {
    dispatch((_, getState) => {
      let state = getState();

      if (state.getIn(['compose', 'text']).trim().length !== 0 && state.getIn(['compose', 'dirty'])) {
        dispatch(openModal('CONFIRM', {
          message: intl.formatMessage(messages.cancelReplyMessage),
          confirm: intl.formatMessage(messages.cancelReplyConfirm),
          onConfirm: () => dispatch(cancelReplyCompose()),
        }));
      } else {
        dispatch(cancelReplyCompose());
      }
    });
  },

});

export default injectIntl(connect(makeMapStateToProps, mapDispatchToProps)(ReplyIndicator));
