import PropTypes from 'prop-types';
import React from 'react';

import { defineMessages, FormattedMessage, injectIntl } from 'react-intl';

import ImmutablePureComponent from 'react-immutable-pure-component';
import { connect } from 'react-redux';

import { fetchFilters, createFilter, createFilterStatus } from 'mastodon/actions/filters';
import IconButton from 'mastodon/components/icon_button';
import AddedToFilter from 'mastodon/features/filters/added_to_filter';
import SelectFilter from 'mastodon/features/filters/select_filter';

const messages = defineMessages({
  close: { id: 'lightbox.close', defaultMessage: 'Close' },
});

class FilterModal extends ImmutablePureComponent {

  static propTypes = {
    statusId: PropTypes.string.isRequired,
    contextType: PropTypes.string,
    dispatch: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    onClose: PropTypes.func.isRequired,
  };

  state = {
    step: 'select',
    filterId: null,
    isSubmitting: false,
    isSubmitted: false,
  };

  handleNewFilterSuccess = (result) => {
    this.handleSelectFilter(result.id);
  }

  handleSuccess = () => {
    this.setState({ isSubmitting: false, isSubmitted: true, step: 'submitted' });
  }

  handleFail = () => {
    this.setState({ isSubmitting: false });
  }

  handleSelectFilter = (filterId) => {
    const { dispatch, statusId } = this.props;

    this.setState({ isSubmitting: true, filterId });

    dispatch(createFilterStatus({
      filter_id: filterId,
      status_id: statusId,
    }, this.handleSuccess, this.handleFail));
  }

  handleNewFilter = (title) => {
    const { dispatch } = this.props;

    this.setState({ isSubmitting: true });

    dispatch(createFilter({
      title,
      context: ['home', 'notifications', 'public', 'thread', 'account'],
      filter_action: 'warn',
    }, this.handleNewFilterSuccess, this.handleFail));
  }

  componentDidMount () {
    const { dispatch } = this.props;

    dispatch(fetchFilters());
  }

  render () {
    const {
      intl,
      statusId,
      contextType,
      onClose,
    } = this.props;

    const {
      step,
      filterId,
      isSubmitting,
    } = this.state;

    let stepComponent = null;

    switch(step) {
    case 'select':
      stepComponent = (
        <SelectFilter
          contextType={contextType}
          onSelectFilter={this.handleSelectFilter}
          onNewFilter={this.handleNewFilter}
        />
      );
      break;
    case 'submitted':
      stepComponent = (
        <AddedToFilter
          filterId={filterId}
          statusId={statusId}
          contextType={contextType}
          onClose={onClose}
        />
      );
      break;
    }

    return (
      <div className='modal-root__modal filter-modal'>
        <div className='filter-modal__container'>
          <div className='filter-modal__target'>
            <IconButton className='media-modal__close' title={intl.formatMessage(messages.close)} icon='times' onClick={onClose} />
            <FormattedMessage id='filter_modal.title' defaultMessage='Filter this post' />
          </div>

          <div className='filter-modal__status' aria-busy={isSubmitting}>
            {stepComponent}
          </div>
        </div>
      </div>
    );
  }

}

export default connect()(injectIntl(FilterModal));
