// server.js - Endpoint para recibir metricas
const express = require('express');
const { Pool } = require('pg');

function createApp(pool) {
    const app = express();

    app.use(express.json());

    // Middleware de autenticacion
    const authenticate = (req, res, next) => {
        const token = req.headers.authorization?.replace('Bearer ', '');
        if (token !== process.env.API_KEY) {
            return res.status(401).json({ error: 'Unauthorized' });
        }
        next();
    };

    // Recibir metricas
    app.post('/api/metrics', authenticate, async (req, res) => {
        const data = req.body;

        try {
            const result = await pool.query(`
                INSERT INTO server_metrics (
                    hostname, ip_public, ip_private, os, kernel, arch,
                    cpu_usage_percent, cpu_cores, cpu_model, cpu_load_avg,
                    mem_total_mb, mem_used_mb, mem_free_mb, mem_usage_percent,
                    disk_total_mb, disk_used_mb, disk_available_mb, disk_usage_percent,
                    load_1min, load_5min, load_15min, saturation_percent,
                    uptime_days, raw_data
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
                         $15, $16, $17, $18, $19, $20, $21, $22, $23, $24)
                RETURNING id
            `, [
                data.system.hostname,
                data.network.public,
                data.network.private,
                data.system.os,
                data.system.kernel,
                data.system.arch,
                data.cpu.usage_percent,
                data.cpu.info.cores,
                data.cpu.info.model,
                data.cpu.info.load_avg,
                data.memory.total_mb,
                data.memory.used_mb,
                data.memory.free_mb,
                data.memory.usage_percent,
                data.disk.root.total_mb,
                data.disk.root.used_mb,
                data.disk.root.available_mb,
                data.disk.root.usage_percent,
                data.saturation.load_1min,
                data.saturation.load_5min,
                data.saturation.load_15min,
                data.saturation.saturation_percent,
                data.uptime_days,
                JSON.stringify(data)
            ]);

            const metricId = result.rows[0].id;

            // Insertar archivos pesados
            if (data.heavy_files && data.heavy_files.length > 0) {
                for (const file of data.heavy_files) {
                    await pool.query(
                        'INSERT INTO heavy_files (metric_id, file_path, file_size) VALUES ($1, $2, $3)',
                        [metricId, file.path, file.size]
                    );
                }
            }

            // Insertar puertos
            if (data.open_ports && data.open_ports.length > 0) {
                for (const port of data.open_ports) {
                    await pool.query(
                        'INSERT INTO open_ports (metric_id, port_number, protocol) VALUES ($1, $2, $3)',
                        [metricId, port.port, port.protocol]
                    );
                }
            }

            // Insertar procesos
            if (data.top_processes && data.top_processes.length > 0) {
                for (const proc of data.top_processes) {
                    await pool.query(
                        'INSERT INTO top_processes (metric_id, pid, username, cpu_percent, mem_percent, command) VALUES ($1, $2, $3, $4, $5, $6)',
                        [metricId, proc.pid, proc.user, proc.cpu, proc.mem, proc.command]
                    );
                }
            }

            res.status(200).json({ success: true, id: metricId });
        } catch (err) {
            console.error('Error:', err);
            res.status(500).json({ error: err.message });
        }
    });

    // Dashboard data
    app.get('/api/dashboard', authenticate, async (req, res) => {
        try {
            const servers = await pool.query(`
                SELECT DISTINCT ON (hostname)
                    hostname, ip_private, cpu_usage_percent, mem_usage_percent,
                    disk_usage_percent, saturation_percent, uptime_days, timestamp
                FROM server_metrics
                ORDER BY hostname, timestamp DESC
            `);
            res.json(servers.rows);
        } catch (err) {
            res.status(500).json({ error: err.message });
        }
    });

    return app;
}

function createPool() {
    return new Pool({
        host: process.env.PGHOST || 'localhost',
        database: process.env.PGDATABASE || 'servmon',
        user: process.env.PGUSER || 'servmon',
        password: process.env.PGPASSWORD || 'tu-password',
        port: Number(process.env.PGPORT || 5432)
    });
}

if (require.main === module) {
    const port = Number(process.env.PORT || 3000);
    const app = createApp(createPool());
    app.listen(port, () => console.log(`ServMon API en puerto ${port}`));
}

module.exports = { createApp, createPool };
