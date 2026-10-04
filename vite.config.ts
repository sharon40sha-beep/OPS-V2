import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Short commit id shown in Settings, to tell which deployed version is running.
const buildId = (process.env.VERCEL_GIT_COMMIT_SHA ?? 'dev').slice(0, 7);

export default defineConfig({
  plugins: [react()],
  define: { __BUILD_ID__: JSON.stringify(buildId) },
});
