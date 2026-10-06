import { connect } from 'react-redux';
import { cancelQuoteCompose } from '../../../actions/compose';
import { openModal } from '../../../actions/modal';
import { targetComposerAction } from '../../../actions/composer';
import { makeGetStatus } from '../../../selectors';
import { selectComposer } from '../../../selectors/composer';
import QuoteIndicator from '../components/quote_indicator';
import { withComposerId } from '../composer_id_context';
import { defineMessages, injectIntl } from 'react-intl';

const messages = defineMessages({
  cancelQuoteConfirm: { id: 'confirmations.cancel_quote.confirm', defaultMessage: 'Canceling quote' },
  cancelQuoteMessage: { id: 'confirmations.cancel_quote.message', defaultMessage: 'Canceling a quote will erase the message you are currently composing. Are you sure you want to proceed?' },
});

const makeMapStateToProps = () => {
  const getStatus = makeGetStatus();

  const mapStateToProps = (state, { composerId }) => {
    const composer = selectComposer(state, composerId);

    return {
      status: getStatus(state, { id: composer.get('quote_from') }),
      isScheduledStatusEditting: !!composer.get('scheduled_status_id'),
    };
  };

  return mapStateToProps;
};

const mapDispatchToProps = (dispatch, { intl, composerId }) => ({

  onCancel () {
    dispatch((_, getState) => {
      const composer = selectComposer(getState(), composerId);
      const cancel = () => dispatch(targetComposerAction(cancelQuoteCompose(), composerId));

      if (composer.get('text').trim().length !== 0 && composer.get('dirty')) {
        dispatch(openModal('CONFIRM', {
          message: intl.formatMessage(messages.cancelQuoteMessage),
          confirm: intl.formatMessage(messages.cancelQuoteConfirm),
          onConfirm: cancel,
        }));
      } else {
        cancel();
      }
    });
  },

});

export default withComposerId(injectIntl(connect(makeMapStateToProps, mapDispatchToProps)(QuoteIndicator)));
