import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import LoadMore from 'mastodon/components/load_more';
import MediaItemsLayout from 'mastodon/components/media_items_layout';
import MediaItem from './media_item';

class LoadMoreMedia extends React.PureComponent {

  static propTypes = {
    maxId: PropTypes.string,
    onLoadMore: PropTypes.func.isRequired,
    disabled: PropTypes.bool,
  };

  handleLoadMore = () => {
    this.props.onLoadMore(this.props.maxId);
  }

  render () {
    return (
      <div className='media-layout__more'>
        <LoadMore
          disabled={this.props.disabled}
          onClick={this.handleLoadMore}
        />
      </div>
    );
  }

}

// Both the account gallery and its regression tests render this component.
// Preserve a tile's identity across visibility policy changes: Masonry uses
// its React key to associate a measured height with its assigned column.
const AccountMediaItems = ({ attachments, shape, size, visibility, onOpenMedia, onReveal, onLoadMore, loadOlder }) => (
  <MediaItemsLayout shape={shape} size={size}>
    {attachments.map((attachment, index) => attachment === null ? (
      // Gap pagination must use the preceding status ID, not the media ID.
      <LoadMoreMedia
        key={'more:' + (attachments.getIn([index + 1, 'id']) || index)}
        maxId={index > 0 ? attachments.getIn([index - 1, 'status', 'id']) : null}
        onLoadMore={onLoadMore}
      />
    ) : (
      <MediaItem key={attachment.get('id')} attachment={attachment} shape={shape} visibility={visibility} onOpenMedia={onOpenMedia} onReveal={onReveal} />
    ))}

    {loadOlder && <div key='more:older' className='media-layout__more'>{loadOlder}</div>}
  </MediaItemsLayout>
);

AccountMediaItems.propTypes = {
  attachments: ImmutablePropTypes.list.isRequired,
  shape: PropTypes.oneOf(['square', 'original']).isRequired,
  size: PropTypes.oneOf(['small', 'medium', 'large', 'max']).isRequired,
  visibility: PropTypes.oneOf(['hide_sensitive', 'show_all', 'hide_all']).isRequired,
  onOpenMedia: PropTypes.func.isRequired,
  onReveal: PropTypes.func,
  onLoadMore: PropTypes.func.isRequired,
  loadOlder: PropTypes.node,
};

export default AccountMediaItems;
