import PropTypes from 'prop-types';
import React, { PureComponent } from 'react';

import { FormattedMessage } from 'react-intl';

import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';

import Button from 'mastodon/components/button';
import CustomEmojiText from 'mastodon/components/custom_emoji_text';
import { toServerSideType } from 'mastodon/utils/filters';

const mapStateToProps = (state, { filterId }) => ({
  filter: state.getIn(['filters', filterId]),
  customEmojis: state.get('custom_emojis'),
});

class AddedToFilter extends PureComponent {

  static propTypes = {
    onClose: PropTypes.func.isRequired,
    contextType: PropTypes.string,
    filter: ImmutablePropTypes.map,
    customEmojis: ImmutablePropTypes.list.isRequired,
    dispatch: PropTypes.func.isRequired,
  };

  handleCloseClick = () => {
    this.props.onClose();
  }

  render () {
    const { filter, contextType, customEmojis } = this.props;

    if (!filter) {
      return null;
    }

    let expiredMessage = null;
    if (filter.get('expires_at') && filter.get('expires_at') < Date.now()) {
      expiredMessage = (
        <p className='filter-modal__warning'>
          <FormattedMessage
            id='filter_modal.added.expired'
            defaultMessage='This filter category has expired and will not apply until you renew it.'
          />
        </p>
      );
    }

    let contextMismatchMessage = null;
    if (contextType && filter.get('context') && !filter.get('context').includes(toServerSideType(contextType))) {
      contextMismatchMessage = (
        <p className='filter-modal__warning'>
          <FormattedMessage
            id='filter_modal.added.context_mismatch'
            defaultMessage='This filter category does not apply to the current timeline.'
          />
        </p>
      );
    }

    const settingsLink = (
      <a href={`/filters/${filter.get('id')}/edit`}>
        <FormattedMessage id='filter_modal.added.settings_link' defaultMessage='Go to filter settings' />
      </a>
    );

    return (
      <div className='filter-modal__added'>
        <h3>
          <FormattedMessage id='filter_modal.added.title' defaultMessage='Filter added!' />
        </h3>

        <p>
          <FormattedMessage
            id='filter_modal.added.subtitle'
            defaultMessage='This post has been added to the “{title}” filter category.'
            values={{ title: <CustomEmojiText text={filter.get('title')} customEmojis={customEmojis} /> }}
          />
        </p>

        {expiredMessage}
        {contextMismatchMessage}

        <p>
          <FormattedMessage
            id='filter_modal.added.short_explanation'
            defaultMessage='You can manage keywords and filtered posts from {settings_link}.'
            values={{ settings_link: settingsLink }}
          />
        </p>

        <div className='filter-modal__action-bar'>
          <Button text={<FormattedMessage id='lightbox.close' defaultMessage='Close' />} onClick={this.handleCloseClick} />
        </div>
      </div>
    );
  }

}

export default connect(mapStateToProps)(AddedToFilter);
