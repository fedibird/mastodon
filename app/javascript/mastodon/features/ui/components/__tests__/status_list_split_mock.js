/* eslint-disable react/prop-types, react/jsx-no-bind */

const React = require('react');
const { useSelector } = require('react-redux');

module.exports = function StatusListContainer (props) {
  const timelineId = props.dataTimelineId || props.timelineId;
  const isPartial = useSelector(state => !!state.getIn(['timelines', timelineId, 'isPartial']));
  const items = useSelector(state => state.getIn(['timelines', timelineId, 'items']));
  let pane = 'single';

  if (props.includePendingItems) {
    pane = 'live';
  } else if (props.dataTimelineId && props.dataTimelineId !== props.timelineId) {
    pane = 'history';
  }

  if (isPartial) {
    return <div data-regenerating='true' data-pane={pane} data-timeline={timelineId} data-context={props.timelineId} />;
  }

  const ids = items && items.toArray ? items.toArray().filter(id => id !== null) : [];

  return (
    <div
      className='scrollable'
      data-pane={pane}
      data-timeline={timelineId}
      data-context={props.timelineId}
      data-bind={props.bindToDocument ? 'document' : 'column'}
      data-track-scroll={props.trackScroll === false ? 'false' : 'true'}
      data-track-intersection={props.trackIntersection === false ? 'false' : 'true'}
      data-manage-scroll={props.manageTimelineScrollState === false ? 'false' : 'true'}
      data-prepend={props.prepend ? 'true' : 'false'}
      data-always-prepend={props.alwaysPrepend ? 'true' : 'false'}
    >
      {props.prepend}
      {ids.map(id => <article key={id} data-id={id} />)}
      {props.onLoadMore && <button type='button' data-testid={`load-${pane}`} onClick={() => props.onLoadMore('70')}>Load more</button>}
    </div>
  );
};
