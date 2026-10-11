import React from 'react';
import PropTypes from 'prop-types';
import { Link } from 'react-router-dom';
import Icon from 'mastodon/components/icon';
import { describeMixSource } from 'mastodon/mix/source_badges';
import { plainMix } from 'mastodon/mix/definition';
import messages from '../messages';

export default class MixInfoPanel extends React.PureComponent {

  static propTypes = {
    id: PropTypes.string.isRequired,
    intl: PropTypes.object.isRequired,
    mix: PropTypes.object,
    mixId: PropTypes.string,
    lists: PropTypes.object,
    accounts: PropTypes.object,
    onKeyDown: PropTypes.func,
  };

  renderSource = (source, index) => {
    const { intl, lists, accounts } = this.props;
    const row = describeMixSource(source, {
      formatMessage: (message, values) => intl.formatMessage(message, values),
      lists,
      accounts,
    });

    if (!row) {
      return null;
    }

    return (
      <li key={row.key || index} className='mix-info__source'>
        <Icon id={row.icon} className='mix-info__icon' fixedWidth aria-hidden='true' />
        <span className='mix-info__label'>{row.label}</span>
        {row.showChip && <span className='mix-info__chip'>{row.typeLabel}</span>}
      </li>
    );
  };

  render () {
    const { id, intl, mix, mixId, onKeyDown } = this.props;
    const plain = plainMix(mix);
    const sources = plain && plain.sources ? plain.sources : [];

    return (
      <div className='mix-info' id={id} role='region' aria-label={intl.formatMessage(messages.mixInfo)} onKeyDown={onKeyDown}>
        <section className='mix-info__section'>
          <h2>{intl.formatMessage(messages.aboutMix)}</h2>
          <p>{intl.formatMessage(messages.aboutMixBody)}</p>
          <p>{intl.formatMessage(messages.notShared)}</p>
        </section>

        <section className='mix-info__section'>
          <h2>{intl.formatMessage(messages.includedSources)}</h2>
          <ul className='mix-info__sources'>
            {sources.map(this.renderSource)}
          </ul>
        </section>

        {mixId && (
          <Link className='button mix-info__edit' to={`/mixes/${mixId}/edit`}>
            {intl.formatMessage(messages.edit)}
          </Link>
        )}
      </div>
    );
  }

}
