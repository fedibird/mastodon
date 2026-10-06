import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';

const messages = defineMessages({
  label: { id: 'compose_form.posting_context', defaultMessage: 'Posting context' },
  include: { id: 'compose_form.posting_context.include', defaultMessage: 'Include #{hashtag}' },
  exclude: { id: 'compose_form.posting_context.exclude', defaultMessage: 'Do not add #{hashtag}' },
});

class ManagedHashtagButton extends React.PureComponent {

  static propTypes = {
    name: PropTypes.string.isRequired,
    normalizedName: PropTypes.string.isRequired,
    suppressed: PropTypes.bool,
    onToggle: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
  };

  handleClick = () => {
    this.props.onToggle(this.props.normalizedName);
  }

  render () {
    const { intl, name, suppressed } = this.props;
    const hashtag = name.replace(/^[#＃]+/u, '');
    const action = intl.formatMessage(suppressed ? messages.include : messages.exclude, { hashtag });

    return (
      <button
        type='button'
        className={classNames('compose-form__posting-context-tag', {
          'compose-form__posting-context-tag--suppressed': suppressed,
        })}
        title={action}
        aria-label={action}
        aria-pressed={!suppressed}
        onClick={this.handleClick}
      >
        {`#${hashtag}`}
        <span aria-hidden='true'>{suppressed ? '＋' : '×'}</span>
      </button>
    );
  }

}

class PostingContextBar extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    hashtags: ImmutablePropTypes.list,
    suppressedHashtags: ImmutablePropTypes.set,
    onToggle: PropTypes.func.isRequired,
  };

  render () {
    const { intl, hashtags, suppressedHashtags, onToggle } = this.props;

    if (!hashtags || hashtags.isEmpty()) {
      return null;
    }

    return (
      <div className='compose-form__posting-context'>
        <span className='compose-form__posting-context-label'>
          {intl.formatMessage(messages.label)}
        </span>
        {hashtags.map(tag => {
          const normalizedName = tag.get('normalizedName');

          return (
            <ManagedHashtagButton
              key={normalizedName}
              name={tag.get('name')}
              normalizedName={normalizedName}
              suppressed={Boolean(suppressedHashtags && suppressedHashtags.includes(normalizedName))}
              onToggle={onToggle}
              intl={intl}
            />
          );
        })}
      </div>
    );
  }

}

export default injectIntl(PostingContextBar);
