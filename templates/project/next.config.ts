import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Standalone output feeds the Docker runner stage: `next build` emits a
  // self-contained server.js with a minimal runtime node_modules.
  output: "standalone",
  // The gates already cover types and lint (`pnpm run check`); the build must
  // never be allowed to silently skip them.
  typescript: { ignoreBuildErrors: false },
  eslint: { ignoreDuringBuilds: false },
  // BUILD_SHA is a RUNTIME contract, deliberately NOT inlined via the `env`
  // key: the Docker runner stage sets ENV BUILD_SHA=<git sha> and
  // /api/health reads process.env.BUILD_SHA on each request. Inlining it at
  // build time would freeze the placeholder value into the bundle.
};

export default nextConfig;
