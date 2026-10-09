import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';

const messages = defineMessages({
  label: { id: 'compose_form.sender.label', defaultMessage: 'Posting as' },
  choose: { id: 'compose_form.sender.choose', defaultMessage: 'Choose who this post is sent as' },
  unavailable: { id: 'compose_form.sender.unavailable', defaultMessage: 'This sender can’t post right now' },
  unconfirmed: { id: 'compose_form.sender.unconfirmed', defaultMessage: 'Couldn’t confirm who this post is sent as' },
  retry: { id: 'compose_form.sender.retry', defaultMessage: 'Confirm sender again' },
});

const accountLabel = account => {
  if (!account || !account.get) {
    return '';
  }

  const acct = account.get('acct');
  const displayName = account.get('display_name');

  if (displayName && acct) {
    return `${displayName} (@${acct})`;
  }

  return acct ? `@${acct}` : '';
};

class SenderIdentity extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    visible: PropTypes.bool,
    account: ImmutablePropTypes.map,
    identities: ImmutablePropTypes.list,
    selectedId: PropTypes.string,
    catalogStatus: PropTypes.string,
    canSend: PropTypes.bool,
    compact: PropTypes.bool,
    onSelect: PropTypes.func,
    onRetry: PropTypes.func,
  };

  static defaultProps = {
    visible: false,
    identities: null,
    canSend: true,
    compact: false,
  };

  handleChange = event => {
    if (this.props.onSelect) {
      this.props.onSelect(event.target.value);
    }
  }

  render () {
    const { intl, visible, account, identities, selectedId, catalogStatus, canSend, compact, onRetry } = this.props;

    if (!visible) {
      return null;
    }

    const selectable = identities ? identities.filter(identity => identity.get('authorization') === 'ready') : null;
    const showChooser = Boolean(selectable && selectable.size > 1 && this.props.onSelect);
    const avatar = account && (account.get('avatar_static') || account.get('avatar'));
    const label = accountLabel(account);
    let notice = null;

    if (catalogStatus === 'failed' || catalogStatus === 'unauthorized') {
      notice = intl.formatMessage(messages.unconfirmed);
    } else if (canSend === false) {
      notice = intl.formatMessage(messages.unavailable);
    }

    return (
      <div className={classNames('compose-form__sender', { 'compose-form__sender--compact': compact })} data-testid='sender-identity'>
        <span className='compose-form__sender-label'>{intl.formatMessage(messages.label)}</span>
        {avatar ? <img className='compose-form__sender-avatar' src={avatar} alt='' /> : null}
        {showChooser ? (
          // The choice commits when it changes. onBlur would leave the old sender selected.
          // eslint-disable-next-line jsx-a11y/no-onchange
          <select
            className='compose-form__sender-select'
            aria-label={intl.formatMessage(messages.choose)}
            value={selectedId || ''}
            onChange={this.handleChange}
          >
            {selectable.map(identity => (
              <option key={identity.get('id')} value={identity.get('id')}>
                {accountLabel(identity.get('account'))}
              </option>
            ))}
          </select>
        ) : (
          <span className='compose-form__sender-acct'>{label}</span>
        )}
        {notice ? <span className='compose-form__sender-notice' role='status'>{notice}</span> : null}
        {catalogStatus === 'failed' && onRetry ? (
          <button type='button' className='compose-form__sender-retry' onClick={onRetry}>
            {intl.formatMessage(messages.retry)}
          </button>
        ) : null}
      </div>
    );
  }

}

export default injectIntl(SenderIdentity);
