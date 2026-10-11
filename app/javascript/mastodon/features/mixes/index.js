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
            <p className='mix-editor__intro'>{intl.formatMessage(messages.editorIntro)}</p>
            <Link className='button mix-list__create' to='/mixes/new'>{intl.formatMessage(messages.create)}</Link>
            <h2 className='mix-editor__label'>{intl.formatMessage(messages.subheading)}</h2>
            {items.isEmpty() && <p>{intl.formatMessage(messages.empty)}</p>}
            {!items.isEmpty() && (
              <ul className='mix-list__items'>
                {items.map(mix => {
                  if (!mix) {
                    return null;
                  }

                  const title = mix.get('title') || intl.formatMessage(messages.heading);
                  const count = mix.get('sources') && mix.get('sources').size ? mix.get('sources').size : 0;

                  return (
                    <li className='list-link mix-list__item' key={mix.get('id')}>
                      <div className='list-name'>
                        <Link className='column-link mix-list__link' to={`/timelines/mixes/${mix.get('id')}`}>
                          <Icon id='random' fixedWidth className='column-link__icon' />
                          <span className='mix-list__text'>
                            <span className='mix-list__title'>{title}</span>
                            <span className='mix-list__summary'>{intl.formatMessage(messages.sourceSummary, { count })}</span>
                          </span>
                        </Link>
                      </div>
                      <Link className='list-edit-button mix-list__edit' to={`/mixes/${mix.get('id')}/edit`} title={intl.formatMessage(messages.edit)} aria-label={intl.formatMessage(messages.edit)}>
                        <Icon id='pencil' className='column-link__icon' fixedWidth />
                      </Link>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        )}
      </Column>
    );
  }

}

export default @connect(mapStateToProps)
@injectIntl
class Mixes extends MixList {}
