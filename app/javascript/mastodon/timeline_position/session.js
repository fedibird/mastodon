import { createPositionRegistry } from './registry';

let registry = createPositionRegistry();

export const getPositionRegistry = () => registry;

export const resetPositionRegistry = () => {
  registry = createPositionRegistry();
  return registry;
};

export const positionAccountId = (candidate) => {
  if (candidate === null || candidate === undefined || candidate === '') {
    registry.noteAccount(null);
    return null;
  }

  return registry.noteAccount(typeof candidate === 'number' ? String(candidate) : candidate);
};
