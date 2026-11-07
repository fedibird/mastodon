import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import {
  FULLSCREEN_COLUMN_CLOSE,
  FULLSCREEN_COLUMN_OPEN,
  FULLSCREEN_COLUMN_PATCH,
} from '../actions/fullscreen_column';

const toMap = (value) => {
  if (!value) {
    return ImmutableMap();
  }

  return ImmutableMap.isMap(value) ? value : fromJS(value);
};

export default function fullscreenColumn (state = null, action) {
  switch (action.type) {
  case FULLSCREEN_COLUMN_OPEN:
    return ImmutableMap({
      open: true,
      viewId: action.viewId,
      composerId: action.composerId,
      source: toMap(action.source),
      presentation: toMap(action.presentation),
      composerOpen: false,
      paths: ImmutableList(),
      anchorStatusId: action.anchorStatusId || null,
    });
  case FULLSCREEN_COLUMN_CLOSE:
    return null;
  case FULLSCREEN_COLUMN_PATCH:
    if (!state) {
      return state;
    }

    return state.merge(toMap(action.patch));
  default:
    return state;
  }
}
