import React from 'react';
import PropTypes from 'prop-types';
import TimelineMasonry from './timeline_masonry';
import { mediaGridColumns } from 'mastodon/utils/media_display';

// Shared by the per-attachment timeline and the account's media gallery.
// Owns layout only; the parent owns view-local controls and reveal policy.
const MediaItemsLayout = ({ shape, size, children, onCaptureLayoutAnchor, onRestoreLayoutAnchor }) => (
  shape === 'original' ? (
    <div className='timeline-media-masonry-wrap'>
      <TimelineMasonry
        mode='media'
        mediaSize={size}
        onCaptureLayoutAnchor={onCaptureLayoutAnchor}
        onRestoreLayoutAnchor={onRestoreLayoutAnchor}
      >
        {children}
      </TimelineMasonry>
    </div>
  ) : (
    <div className='timeline-media-grid' style={{ gridTemplateColumns: mediaGridColumns(size) }}>
      {children}
    </div>
  )
);

MediaItemsLayout.propTypes = {
  children: PropTypes.node,
  onCaptureLayoutAnchor: PropTypes.func,
  onRestoreLayoutAnchor: PropTypes.func,
  shape: PropTypes.oneOf(['square', 'original']).isRequired,
  size: PropTypes.oneOf(['small', 'medium', 'large', 'max']).isRequired,
};

export default MediaItemsLayout;
