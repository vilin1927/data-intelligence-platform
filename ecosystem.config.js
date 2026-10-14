// PM2 Ecosystem File — BUG-25 (CRITICAL #12 from 2026-04-11 CTO audit)
//
// Purpose: Run the Next.js dashboard in PM2 cluster mode (2 instances) so
// that a single worker crash no longer takes the site down. The audit on
// 2026-04-11 found a single PM2 process for moppity-dashboard with restart
// count = 122 over 28 min uptime — elevated and under investigation.
//
// Deploy:
//   scp ecosystem.config.js root@your-server-ip:/opt/moppity/ecosystem.config.js
//   ssh root@your-server-ip
//   pm2 delete moppity-dashboard   # remove the old single-process entry
//   pm2 start /opt/moppity/ecosystem.config.js
//   pm2 save
//   pm2 startup systemd -u root --hp /root   # persist across reboots
//
// Verify:
//   pm2 status                     # should show 2 online workers, mode=cluster
//   pm2 logs moppity-dashboard     # watch for a clean boot
//   curl -sS http://localhost:3000/api/status
//
// (/opt/moppity/dashboard). The `script: 'npm'` + `args: 'start'` pairing
// mirrors the existing `pm2 start npm --name "moppity-dashboard" -- start`

module.exports = {
  apps: [
    {
      name: 'moppity-dashboard',
      cwd: '/opt/moppity/dashboard',
      script: 'npm',
      args: 'start',
      instances: 2,
      exec_mode: 'cluster',
      max_memory_restart: '1G',
      // Restart backoff: if the app crashes in a loop, wait longer each
      // time instead of hammering the CPU (related to the 122-restart
      // issue flagged in the audit).
      min_uptime: '30s',
      max_restarts: 10,
      restart_delay: 2000,
      exp_backoff_restart_delay: 200,
      // Log files — `merge_logs: true` combines stdout/stderr from both
      // cluster workers into one stream so `pm2 logs` is readable.
      error_file: '/var/log/moppity-dashboard-error.log',
      out_file: '/var/log/moppity-dashboard-out.log',
      merge_logs: true,
      time: true,
      env: {
        NODE_ENV: 'production',
        PORT: 3000,
      },
    },
  ],
};
