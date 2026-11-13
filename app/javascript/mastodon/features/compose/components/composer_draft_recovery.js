import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';

const messages = defineMessages({
  restore: { id: 'compose_form.draft_restore', defaultMessage: 'Restore local draft' },
  restoreCount: { id: 'compose_form.draft_restore_count', defaultMessage: 'Restore local draft ({count})' },
  saveFailed: { id: 'compose_form.draft_save_failed', defaultMessage: 'This draft could not be saved on this device. Reloading may lose the latest changes.' },
  unavailable: { id: 'compose_form.draft_unavailable', defaultMessage: 'This browser cannot store drafts on this device.' },
  mediaIncomplete: { id: 'compose_form.draft_media_incomplete', defaultMessage: 'Attachments that are still uploading were not saved.' },
});

class ComposerDraftRecovery extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    offerId: PropTypes.string,
    offerCount: PropTypes.number,
    status: PropTypes.string,
    reason: PropTypes.string,
    mediaIncomplete: PropTypes.bool,
    onRestore: PropTypes.func,
  };

  handleRestore = () => {
    const { offerId, onRestore } = this.props;

    if (offerId && onRestore) {
      onRestore(offerId);
    }
  };

  render () {
    const { intl, offerId, offerCount, status, reason, mediaIncomplete } = this.props;
    const failed = status === 'failed';
    const unavailable = failed && reason === 'unavailable';
    const showMedia = mediaIncomplete === true && status === 'saved';

    if (!offerId && !failed && !showMedia) {
      return null;
    }

    const restoreLabel = offerCount > 1
      ? intl.formatMessage(messages.restoreCount, { count: offerCount })
      : intl.formatMessage(messages.restore);

    return (
      <div className='compose-form__draft-recovery' role='status'>
        {unavailable && <p>{intl.formatMessage(messages.unavailable)}</p>}
        {failed && !unavailable && <p>{intl.formatMessage(messages.saveFailed)}</p>}
        {showMedia && <p>{intl.formatMessage(messages.mediaIncomplete)}</p>}
        {offerId && (
          <button type='button' className='compose-form__draft-recovery__restore' onClick={this.handleRestore}>
            {restoreLabel}
          </button>
        )}
      </div>
    );
  }

}

export default injectIntl(ComposerDraftRecovery);
