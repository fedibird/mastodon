import React from 'react';
import { connect } from 'react-redux';
import { Link } from 'react-router-dom';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { injectIntl } from 'react-intl';
import { List as ImmutableList } from 'immutable';
import Column from '../ui/components/column';
import ColumnBackButtonSlim from '../../components/column_back_button_slim';
import Icon from 'mastodon/components/icon';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { describeMixSource } from 'mastodon/mix/source_badges';
import messages from './messages';

const mapStateToProps = state => ({
  mixes: state.getIn(['settings', 'mixes'], ImmutableList()),
  lists: state.get('lists'),
  accounts: state.get('accounts'),
  columnWidth: defaultColumnWidth,
});

const sourceRows = (mix, formatMessage, lists, accounts) => {
  const sources = mix && mix.get ? mix.get('sources') : null;

  if (!sources || typeof sources.forEach !== 'function') {
    return [];
  }

  const rows = [];

  sources.forEach((source, index) => {
    let row = null;

    try {
      row = describeMixSource(source, { formatMessage, lists, accounts });
    } catch (error) {
      row = null;
    }

    if (row) {
      rows.push({ ...row, position: index });
    }
  });

  return rows;
};

class MixListItem extends React.PureComponent {

  static propTypes = {
    mix: ImmutablePropTypes.map.isRequired,
    intl: PropTypes.object.isRequired,
    lists: PropTypes.object,
    accounts: PropTypes.object,
  };

  render () {
    const { mix, intl, lists, accounts } = this.props;
    const title = mix.get('title') || intl.formatMessage(messages.heading);
    const settingsLabel = intl.formatMessage(messages.settings);
    const rows = sourceRows(mix, (message, values) => intl.formatMessage(message, values), lists, accounts);

    return (
      <li className='mix-list__item'>
        <Link className='mix-list__link' to={`/timelines/mixes/${mix.get('id')}`}>
          <Icon id='random' fixedWidth className='column-link__icon' />
          <span className='mix-list__text'>
            <span className='mix-list__title'>{title}</span>
            {rows.length > 0 && (
              <span className='mix-list__sources'>
                {rows.map(row => (
                  <span className='mix-list__source' key={`${row.key || 'source'}:${row.position}`}>
                    <Icon id={row.icon} className='mix-list__source-icon' aria-hidden='true' />
                    <span className='mix-list__source-label'>{row.label}</span>
                  </span>
                ))}
              </span>
            )}
          </span>
        </Link>
        <Link className='mix-list__settings' to={`/mixes/${mix.get('id')}/edit`} title={settingsLabel} aria-label={settingsLabel}>
          <Icon id='sliders' fixedWidth aria-hidden='true' />
        </Link>
      </li>
    );
  }

}

export class MixList extends React.PureComponent {

  static propTypes = {
    mixes: ImmutablePropTypes.list,
    lists: PropTypes.object,
    accounts: PropTypes.object,
    intl: PropTypes.object.isRequired,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
  };

  render () {
    const { mixes, lists, accounts, intl, multiColumn, columnWidth } = this.props;
    const items = mixes || ImmutableList();

    return (
      <Column bindToDocument={!multiColumn} icon='random' heading={intl.formatMessage(messages.heading)} columnWidth={columnWidth}>
        <ColumnBackButtonSlim />
        <div className='mix-editor'>
          <p className='mix-editor__intro'>{intl.formatMessage(messages.editorIntro)}</p>
          <Link className='button mix-list__create' to='/mixes/new'>{intl.formatMessage(messages.create)}</Link>
          <h2 className='mix-editor__label'>{intl.formatMessage(messages.subheading)}</h2>
          {items.isEmpty() && <p>{intl.formatMessage(messages.empty)}</p>}
          {!items.isEmpty() && (
            <ul className='mix-list__items'>
              {items.map(mix => mix && (
                <MixListItem key={mix.get('id')} mix={mix} intl={intl} lists={lists} accounts={accounts} />
              ))}
            </ul>
          )}
        </div>
      </Column>
    );
  }

}

export default @connect(mapStateToProps)
@injectIntl
class Mixes extends MixList {}
