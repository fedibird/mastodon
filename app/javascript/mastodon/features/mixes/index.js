import React from 'react';
import { connect } from 'react-redux';
import { Link } from 'react-router-dom';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { injectIntl } from 'react-intl';
import { List as ImmutableList } from 'immutable';
import Column from '../ui/components/column';
import ColumnLink from '../ui/components/column_link';
import ColumnBackButtonSlim from '../../components/column_back_button_slim';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { isMixEnabled } from 'mastodon/mix/availability';
import messages from './messages';

const mapStateToProps = state => ({
  mixes: state.getIn(['settings', 'mixes'], ImmutableList()),
  enabled: isMixEnabled(),
  columnWidth: defaultColumnWidth,
});

export class MixList extends React.PureComponent {

  static propTypes = {
    mixes: ImmutablePropTypes.list,
    enabled: PropTypes.bool,
    intl: PropTypes.object.isRequired,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
  };

  render () {
    const { mixes, enabled, intl, multiColumn, columnWidth } = this.props;
    const items = mixes || ImmutableList();

    return (
      <Column bindToDocument={!multiColumn} icon='random' heading={intl.formatMessage(messages.heading)} columnWidth={columnWidth}>
        <ColumnBackButtonSlim />
        {!enabled && <p className='mix-editor__notice'>{intl.formatMessage(messages.unavailable)}</p>}
        {enabled && (
          <div className='mix-editor'>
            <Link className='button' to='/mixes/new'>{intl.formatMessage(messages.create)}</Link>
            <h2 className='mix-editor__label'>{intl.formatMessage(messages.subheading)}</h2>
            {items.isEmpty() && <p>{intl.formatMessage(messages.empty)}</p>}
            {items.map(mix => mix && (
              <div className='list-link' key={mix.get('id')}>
                <div className='list-name'>
                  <ColumnLink icon='random' text={mix.get('title') || intl.formatMessage(messages.heading)} to={`/timelines/mixes/${mix.get('id')}`} />
                </div>
                <Link className='list-edit-button' to={`/mixes/${mix.get('id')}/edit`}>{intl.formatMessage(messages.edit)}</Link>
              </div>
            ))}
          </div>
        )}
      </Column>
    );
  }

}

export default @connect(mapStateToProps)
@injectIntl
class Mixes extends MixList {}
