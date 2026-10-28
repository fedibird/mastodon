import { reduceExternalPlayerAction } from './session';

export default function externalPlayerMiddleware () {
  return next => action => {
    const result = next(action);
    reduceExternalPlayerAction(action);
    return result;
  };
}
