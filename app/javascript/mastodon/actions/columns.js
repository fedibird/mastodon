import { Map as ImmutableMap } from 'immutable';
import { changeSetting, saveSettings } from './settings';

export const COLUMN_ADD           = 'COLUMN_ADD';
export const COLUMN_REMOVE        = 'COLUMN_REMOVE';
export const COLUMN_MOVE          = 'COLUMN_MOVE';
export const COLUMN_PARAMS_CHANGE = 'COLUMN_PARAMS_CHANGE';

export function addColumn(id, params) {
  return dispatch => {
    dispatch({
      type: COLUMN_ADD,
      id,
      params,
    });

    dispatch(saveSettings());
  };
};

export function removeColumn(uuid) {
  return dispatch => {
    dispatch({
      type: COLUMN_REMOVE,
      uuid,
    });

    dispatch(saveSettings());
  };
};

export function moveColumn(uuid, direction) {
  return dispatch => {
    dispatch({
      type: COLUMN_MOVE,
      uuid,
      direction,
    });

    dispatch(saveSettings());
  };
};

export function changeColumnParams(uuid, path, value) {
  return dispatch => {
    dispatch({
      type: COLUMN_PARAMS_CHANGE,
      uuid,
      path: Array.isArray(path) ? path : [path],
      value,
    });

    dispatch(saveSettings());
  };
}


// Apply layout mode and an optional width upgrade as a single settings write.
// Retain all existing column params and independent standalone preferences.
export function changeTimelineLayout({ columnId, scope, layoutMode, columnWidth }) {
  return (dispatch, getState) => {
    if (!scope) {
      return;
    }

    if (columnId) {
      const columns = getState().getIn(['settings', 'columns']);
      const column = columns && columns.find(item => item.get('uuid') === columnId);
      if (!column) {
        return;
      }

      let params = column.get('params', ImmutableMap()).set('layoutMode', layoutMode);
      if (columnWidth !== undefined) {
        params = params.set('columnWidth', columnWidth);
      }

      dispatch(changeColumnParams(columnId, [], params));
    } else {
      let settings = getState().getIn(['settings', scope], ImmutableMap()).set('layoutMode', layoutMode);
      if (columnWidth !== undefined) {
        settings = settings.set('columnWidth', columnWidth);
      }

      dispatch(changeSetting([scope], settings));
    }
  };
}
