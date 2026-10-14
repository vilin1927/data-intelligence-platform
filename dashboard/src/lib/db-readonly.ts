import { Pool } from 'pg';

// Read-only database pool for AI chat queries.
// Connects as moppity_readonly (SELECT-only) with a 5-second statement timeout.

let pool: Pool;

function getReadonlyPool(): Pool {
  if (!pool) {
    const connectionString = process.env.DATABASE_URL_READONLY || process.env.DATABASE_URL;
    if (!connectionString) {
      throw new Error(
        'DATABASE_URL_READONLY (or DATABASE_URL) environment variable is not set.'
      );
    }
    pool = new Pool({
      connectionString,
      max: 3,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    });

    pool.on('error', (err) => {
      console.error('[db-readonly] Unexpected pool error:', err.message);
    });
  }
  return pool;
}

export default getReadonlyPool;
