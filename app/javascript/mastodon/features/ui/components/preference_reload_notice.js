import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { defineMessages, FormattedMessage, injectIntl } from 'react-intl';
import { selectPreferenceReloadRequired } from 'mastodon/selectors/user_preferences';
import { confirmPreferenceReload, stateHasComposerDraft } from 'mastodon/utils/preference_apply';

const messages = defineMessages({
  required: {
    id: 'preferences.reload_required',
    defaultMessage: 'Font size or reduced-motion preferences changed. Reload to apply them. Unsent posts stay until you reload.',
  },
  reload: { id: 'preferences.reload', defaultMessage: 'Reload' },
  confirm: {
    id: 'preferences.reload_confirm',
    defaultMessage: 'Reloading will discard unsent posts. Reload anyway?',
  },
});

export class PreferenceReloadNotice extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    visible: PropTypes.bool,
    hasDraft: PropTypes.bool,
    confirm: PropTypes.func,
    reload: PropTypes.func,
  };

  handleReload = () => {
    const { hasDraft, intl } = this.props;
    const confirm = this.props.confirm || (message => window.confirm(message));
    const reload = this.props.reload || (() => window.location.reload());

    confirmPreferenceReload({
      hasDraft,
      confirm,
      reload,
      message: intl.formatMessage(messages.confirm),
    });
  };

  render () {
    if (!this.props.visible) {
      return null;
    }

    return (
      <div className='preference-reload-notice' role='status'>
        <p className='preference-reload-notice__text'>
          <FormattedMessage {...messages.required} />
        </p>
        <button type='button' className='button' onClick={this.handleReload}>
          <FormattedMessage {...messages.reload} />
        </button>
      </div>
    );
  }

}

const mapStateToProps = state => ({
  visible: selectPreferenceReloadRequired(state),
  hasDraft: stateHasComposerDraft(state),
});

export default connect(mapStateToProps)(injectIntl(PreferenceReloadNotice));
