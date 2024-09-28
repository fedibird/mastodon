import React, { Fragment } from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl, FormattedMessage, FormattedDate } from 'react-intl';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { me, hideJoinedDateFromYourself } from 'mastodon/initial_state';
import Icon from 'mastodon/components/icon';
import Content from 'mastodon/components/content';
import AccountNoteContainer from '../containers/account_note_container';
import age from 's-age';
import classNames from 'classnames';

const messages = defineMessages({
  linkVerifiedOn: { id: 'account.link_verified_on', defaultMessage: 'Ownership of this link was checked on {date}' },
  birth_month_1: { id: 'account.birthday.month.1', defaultMessage: 'January' },
  birth_month_2: { id: 'account.birthday.month.2', defaultMessage: 'February' },
  birth_month_3: { id: 'account.birthday.month.3', defaultMessage: 'March' },
  birth_month_4: { id: 'account.birthday.month.4', defaultMessage: 'April' },
  birth_month_5: { id: 'account.birthday.month.5', defaultMessage: 'May' },
  birth_month_6: { id: 'account.birthday.month.6', defaultMessage: 'June' },
  birth_month_7: { id: 'account.birthday.month.7', defaultMessage: 'July' },
  birth_month_8: { id: 'account.birthday.month.8', defaultMessage: 'August' },
  birth_month_9: { id: 'account.birthday.month.9', defaultMessage: 'September' },
  birth_month_10: { id: 'account.birthday.month.10', defaultMessage: 'October' },
  birth_month_11: { id: 'account.birthday.month.11', defaultMessage: 'November' },
  birth_month_12: { id: 'account.birthday.month.12', defaultMessage: 'December' },
});

const dateFormatOptions = {
  month: 'short',
  day: 'numeric',
  year: 'numeric',
  hour12: false,
  hour: '2-digit',
  minute: '2-digit',
};

export default @injectIntl
class HeaderExtra extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    account: ImmutablePropTypes.map,
    identity_proofs: ImmutablePropTypes.list,
    intl: PropTypes.object.isRequired,
  };

  isStatusesPageActive = (match, location) => {
    if (!match) {
      return false;
    }

    return !location.pathname.match(/\/(followers|following)\/?$/);
  }

  render () {
    const { account, intl, identity_proofs } = this.props;

    if (!account) {
      return null;
    }

    const suspended = account.get('suspended');
    const following = account.getIn(['relationship', 'following']);

    const contentHtml = { __html: account.get('note_emojified') };
    const followed_message = account.get('followed_message_emojified');

    const fields  = account.get('fields');

    const location = account.getIn(['other_settings', 'location']);
    const joined = account.get('created_at');

    const birthday = (() => {
      const birth_year  = account.getIn(['other_settings', 'birth_year'], null);
      const birth_month = account.getIn(['other_settings', 'birth_month'], null);
      const birth_day   = account.getIn(['other_settings', 'birth_day'], null);

      const birth_month_name = birth_month >= 1 && birth_month <= 12 ? intl.formatMessage(messages[`birth_month_${birth_month}`]) : null;

      if (birth_year && birth_month && birth_day) {
        const date = new Date(birth_year, birth_month - 1, birth_day);
        return <Fragment><FormattedDate value={date} hour12={false} year='numeric' month='short' day='2-digit' />(<FormattedMessage id='account.age' defaultMessage='{age} years old}' values={{ age: age(date) }} />)</Fragment>;
      } else if (birth_month && birth_day) {
        return <FormattedMessage id='account.birthday.month_day' defaultMessage='{month_name} {day}' values={{ month: birth_month, day: birth_day, month_name: birth_month_name }} />;
      } else if (birth_year && birth_month) {
        return <FormattedMessage id='account.birthday.year_month' defaultMessage='{month_name}, {year}' values={{ year: birth_year, month: birth_month, month_name: birth_month_name }} />;
      } else if (birth_year) {
        return <FormattedMessage id='account.birthday.year' defaultMessage='{year}' values={{ year: birth_year }} />;
      } else if (birth_month) {
        return <FormattedMessage id='account.birthday.month' defaultMessage='{month_name}' values={{ month: birth_month, day: birth_day, month_name: birth_month_name }} />;
      } else if (birth_day) {
        return null;
      } else {
        const date = account.getIn(['other_settings', 'birthday'], null);
        if (date) {
          return <Fragment><FormattedDate value={date} hour12={false} year='numeric' month='short' day='2-digit' />(<FormattedMessage id='account.age' defaultMessage='{age} years old}' values={{ age: age(date) }} />)</Fragment>;
        } else {
          return null;
        }
      }
    })();

    return (
      <div className={classNames('account__header', 'advanced', { inactive: !!account.get('moved') })} >
        <div className='account__header__extra'>
          <div className='account__header__bio'>
            {(following || account.get('id') === me) && account.get('followed_message') && <div className='account__header__followed_message translate'>
              <label className='account__header__followed_message_header'><FormattedMessage id='account.followed_message_header' defaultMessage='Message to followers' /></label>
              <Content contentHtml={{ __html: followed_message }} />
            </div>}

            {(fields.size > 0 || identity_proofs.size > 0) && (
              <div className='account__header__fields'>
                {identity_proofs.map((proof, i) => (
                  <dl key={i}>
                    <dt dangerouslySetInnerHTML={{ __html: proof.get('provider') }} />

                    <dd className='verified'>
                      <a href={proof.get('proof_url')} target='_blank' rel='noopener noreferrer'><span title={intl.formatMessage(messages.linkVerifiedOn, { date: intl.formatDate(proof.get('updated_at'), dateFormatOptions) })}>
                        <Icon id='check' className='verified__mark' />
                      </span></a>
                      <a href={proof.get('profile_url')} target='_blank' rel='noopener noreferrer'><span dangerouslySetInnerHTML={{ __html: ' '+proof.get('provider_username') }} /></a>
                    </dd>
                  </dl>
                ))}
                {fields.map((pair, i) => (
                  <dl key={i}>
                    <dt dangerouslySetInnerHTML={{ __html: pair.get('name_emojified') }} title={pair.get('name')} className='translate' />

                    <dd className={`${pair.get('verified_at') ? 'verified' : ''} translate`} title={pair.get('value_plain')}>
                      {pair.get('verified_at') && <span title={intl.formatMessage(messages.linkVerifiedOn, { date: intl.formatDate(pair.get('verified_at'), dateFormatOptions) })}><Icon id='check' className='verified__mark' /></span>} <Content contentHtml={{ __html: pair.get('value_emojified') }} />
                    </dd>
                  </dl>
                ))}
              </div>
            )}

            {account.get('id') !== me && !suspended && <AccountNoteContainer account={account} />}

            {account.get('note').length > 0 && account.get('note') !== '<p></p>' && <div className='account__header__content translate'><Content contentHtml={contentHtml} /></div>}

            <div className='account__header__personal--wrapper'>
              <table className='account__header__personal'>
                <tbody>
                  {location && <tr>
                    <th><Icon id='map-marker' fixedWidth aria-hidden='true' /> <FormattedMessage id='account.location' defaultMessage='Location' /></th>
                    <td>{location}</td>
                  </tr>}
                  {birthday && <tr>
                    <th><Icon id='birthday-cake' fixedWidth aria-hidden='true' /> <FormattedMessage id='account.birthday' defaultMessage='Birthday' /></th>
                    <td>{birthday}</td>
                  </tr>}
                  {!(hideJoinedDateFromYourself && account.get('id') === me) && <tr>
                    <th><Icon id='calendar' fixedWidth aria-hidden='true' /> <FormattedMessage id='account.joined' defaultMessage='Joined' /></th>
                    <td><FormattedDate value={joined} hour12={false} year='numeric' month='short' day='2-digit' /></td>
                  </tr>}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    );
  }

}
