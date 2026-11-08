// Raw boot data has no application imports. Lightweight entry points can read
// authentication and scalar preferences without pulling in status rendering.
const element = document.getElementById('initial-state');
const initialState = element && JSON.parse(element.textContent);

export default initialState;
