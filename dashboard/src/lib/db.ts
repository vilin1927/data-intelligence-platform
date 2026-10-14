import { Pool } from 'pg';

// Singleton pool — reused across all API route invocations.
// Next.js API routes are serverless-like but within the same Node process,
// so a module-level pool is the correct pattern.

let pool: Pool;

function getPool(): Pool {
  if (!pool) {
    const connectionString = process.env.DATABASE_URL;
    if (!connectionString) {
      throw new Error(
        'DATABASE_URL environment variable is not set. ' +
        'Copy .env.local.example to .env.local and set the connection string.'
      );
    }
    pool = new Pool({
      connectionString,
      max: 5,                // Small pool — single admin user
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    });

    // Log connection errors (don't crash the process)
    pool.on('error', (err) => {
      console.error('[db] Unexpected pool error:', err.message);
    });
  }
  return pool;
}

export default getPool;
