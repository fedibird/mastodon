import { createStore, applyMiddleware, compose } from 'redux';
import thunk from 'redux-thunk';
import appReducer from '../reducers';
import loadingBarMiddleware from '../middleware/loading_bar';
import errorsMiddleware from '../middleware/errors';
import soundsMiddleware from '../middleware/sounds';
import externalPlayerMiddleware from '../external_player/middleware';
import { filterReconciliationMiddleware } from '../filter_reconciliation/scheduler';
import { composerDraftRecoveryEnabled } from '../drafts/feature';
import { composerDraftMiddleware } from '../drafts/middleware';

export default function configureStore() {
  const middleware = [
    thunk,
    externalPlayerMiddleware,
    filterReconciliationMiddleware,
    loadingBarMiddleware({ promiseTypeSuffixes: ['REQUEST', 'SUCCESS', 'FAIL'] }),
    errorsMiddleware(),
    soundsMiddleware(),
  ];

  if (composerDraftRecoveryEnabled()) {
    middleware.splice(1, 0, composerDraftMiddleware());
  }

  return createStore(appReducer, compose(applyMiddleware(...middleware), window.__REDUX_DEVTOOLS_EXTENSION__ ? window.__REDUX_DEVTOOLS_EXTENSION__() : f => f));
};
