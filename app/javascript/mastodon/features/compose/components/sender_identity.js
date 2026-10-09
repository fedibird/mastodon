import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';

const messages = defineMessages({
  label: { id: 'compose_form.sender_identity.label', defaultMessage: 'Posting as' },
  hint: { id: 'compose_form.sender_identity.hint', defaultMessage: 'This does not change the account you are logged in as.' },
  unavailable: { id: 'compose_form.sender_identity.unavailable', defaultMessage: 'Posting as this identity isn’t available.' },
  failed: { id: 'compose_form.sender_identity.failed', defaultMessage: 'Couldn’t confirm who this post is from.' },
  retry: { id: 'compose_form.sender_identity.retry', defaultMessage: 'Retry' },
  choice: { id: 'compose_form.sender_identity.choice', defaultMessage: 'Post as {acct}' },
});

const accountField = (account, camel, snake) => {
  if (!account || !account.get) {
    return '';
  }

  return account.get(camel) || account.get(snake) || '';
};

const accountAcct = account => accountField(account, 'acct', 'acct');

const accountName = account => accountField(account, 'displayName', 'display_name');

const accountAvatar = account => accountField(account, 'avatarStatic', 'avatar_static') || accountField(account, 'avatar', 'avatar');

class SenderIdentity extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    current: ImmutablePropTypes.map,
    choices: ImmutablePropTypes.list,
    selectedId: PropTypes.string,
    failed: PropTypes.bool,
    onSelect: PropTypes.func,
    onRetry: PropTypes.func,
    compact: PropTypes.bool,
  };

  handleSelect = event => {
    const identityId = event.currentTarget.getAttribute('data-identity-id');

    if (this.props.onSelect && identityId) {
      this.props.onSelect(identityId);
    }
  };

  renderAvatar (account) {
    const src = accountAvatar(account);

    if (!src) {
      return null;
    }

    return <img className='compose-form__sender-avatar' src={src} alt='' />;
  }

  renderIdentity (account) {
    const acct = accountAcct(account);
    const name = accountName(account);

    return (
      <React.Fragment>
        {this.renderAvatar(account)}
        <span className='compose-form__sender-acct'>
          {acct ? `@${acct}` : name}
        </span>
      </React.Fragment>
    );
  }

  render () {
    const { intl, current, choices, selectedId, failed, compact } = this.props;
    const readyChoices = choices && choices.filter ? choices.filter(item => item.get('authorization') === 'ready') : null;
    const several = Boolean(readyChoices && readyChoices.size > 1);
    const authorization = current && current.get('authorization');
    const unavailable = authorization && authorization !== 'ready';

    return (
      <div
        className={classNames('compose-form__sender', { 'compose-form__sender--compact': compact })}
        data-testid='sender-identity'
        title={intl.formatMessage(messages.hint)}
      >
        <span className='compose-form__sender-label'>{intl.formatMessage(messages.label)}</span>
        {several ? (
          <div className='compose-form__sender-choices' role='group' aria-label={intl.formatMessage(messages.label)}>
            {readyChoices.map(choice => (
              <button
                key={choice.get('id')}
                type='button'
                className={classNames('compose-form__sender-choice', { active: choice.get('id') === selectedId })}
                data-identity-id={choice.get('id')}
                aria-pressed={choice.get('id') === selectedId}
                title={intl.formatMessage(messages.choice, { acct: accountAcct(choice.get('account')) })}
                onClick={this.handleSelect}
              >
                {this.renderIdentity(choice.get('account'))}
              </button>
            ))}
          </div>
        ) : (
          <span className='compose-form__sender-current' data-testid='sender-identity-current'>
            {this.renderIdentity(current && current.get('account') ? current.get('account') : current)}
          </span>
        )}
        <p className='compose-form__sender-hint'>{intl.formatMessage(messages.hint)}</p>
        {failed ? (
          <p className='compose-form__sender-status' role='status'>
            {intl.formatMessage(messages.failed)}
            {this.props.onRetry ? (
              <button type='button' className='compose-form__sender-retry' onClick={this.props.onRetry}>
                {intl.formatMessage(messages.retry)}
              </button>
            ) : null}
          </p>
        ) : null}
        {unavailable && !failed ? (
          <p className='compose-form__sender-status' role='status'>{intl.formatMessage(messages.unavailable)}</p>
        ) : null}
      </div>
    );
  }

}

export default injectIntl(SenderIdentity);
