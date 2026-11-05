import React from 'react';
import { createRoot } from 'react-dom/client';

function App() {
  return <div>env: {import.meta.env.VITE_DEPLOYMENT_ENV}</div>;
}

createRoot(document.getElementById('root')).render(<App />);
