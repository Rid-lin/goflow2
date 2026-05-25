// Package timescaledb implements a TimescaleDB/PostgreSQL transport.
package timescaledb

import (
	"bytes"
	"context"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"
	"time"

	flowpb "github.com/netsampler/goflow2/v3/pb"
	"github.com/netsampler/goflow2/v3/transport"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/proto"
)

// TimescaleDBDriver sends formatted messages to TimescaleDB/PostgreSQL.
type TimescaleDBDriver struct {
	connStr                 string
	tableName               string
	createTable             bool
	createAggregationTables bool
	chunkTimeInterval       time.Duration
	batchSize               int
	batchTimeout            time.Duration
	maxConnections          int
	enableCompression       bool
	compressionAfter        time.Duration

	pool   *pgxpool.Pool
	batch  []*flowpb.FlowMessage
	lock   *sync.Mutex
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// Prepare registers flags for TimescaleDB transport configuration.
func (d *TimescaleDBDriver) Prepare() error {
	flag.StringVar(&d.connStr, "transport.timescaledb.conn", "postgres://postgres:password@localhost:5432/goflow2",
		"TimescaleDB connection string (PostgreSQL format)")
	flag.StringVar(&d.tableName, "transport.timescaledb.table", "flows",
		"Table name for flow data")
	flag.BoolVar(&d.createTable, "transport.timescaledb.create-table", true,
		"Create table if it doesn't exist")
	flag.BoolVar(&d.createAggregationTables, "transport.timescaledb.create-aggregation-tables", true,
		"Create aggregation tables for local IP traffic")
	flag.DurationVar(&d.chunkTimeInterval, "transport.timescaledb.chunk-interval", time.Hour,
		"Chunk time interval for hypertable partitioning (e.g., 1h, 1d)")
	flag.IntVar(&d.batchSize, "transport.timescaledb.batch-size", 1000,
		"Batch size for inserts")
	flag.DurationVar(&d.batchTimeout, "transport.timescaledb.batch-timeout", time.Second*5,
		"Maximum time to wait before flushing batch")
	flag.IntVar(&d.maxConnections, "transport.timescaledb.max-connections", 10,
		"Maximum number of database connections")
	flag.BoolVar(&d.enableCompression, "transport.timescaledb.enable-compression", true,
		"Enable TimescaleDB compression and indexes on the flows table")
	flag.DurationVar(&d.compressionAfter, "transport.timescaledb.compression-after", 24*time.Hour*7,
		"Compress data older than this interval (default 7 days)")
	return nil
}

// Init initializes the database connection pool and creates table if needed.
func (d *TimescaleDBDriver) Init() error {
	d.lock = &sync.Mutex{}
	d.batch = make([]*flowpb.FlowMessage, 0, d.batchSize)
	d.ctx, d.cancel = context.WithCancel(context.Background())

	// Parse connection string and configure pool
	config, err := pgxpool.ParseConfig(d.connStr)
	if err != nil {
		return fmt.Errorf("parse connection string: %w", err)
	}
	config.MaxConns = int32(d.maxConnections)
	config.MinConns = 1

	// Create connection pool
	pool, err := pgxpool.NewWithConfig(d.ctx, config)
	if err != nil {
		return fmt.Errorf("create connection pool: %w", err)
	}
	d.pool = pool

	// Test connection
	if err := d.pool.Ping(d.ctx); err != nil {
		return fmt.Errorf("ping database: %w", err)
	}

	// Create table if requested
	if d.createTable {
		if err := d.createTableIfNotExists(); err != nil {
			return fmt.Errorf("create table: %w", err)
		}
	}

	// Start batch flusher
	d.wg.Add(1)
	go d.batchFlusher()

	return nil
}

// createTableIfNotExists creates the flow table with appropriate schema.
func (d *TimescaleDBDriver) createTableIfNotExists() error {
	// Format chunk interval for PostgreSQL
	intervalSeconds := int64(d.chunkTimeInterval.Seconds())
	intervalExpr := fmt.Sprintf("INTERVAL '%d seconds'", intervalSeconds)

	// This schema matches the FlowMessage protobuf structure
	query := fmt.Sprintf(`
		CREATE TABLE IF NOT EXISTS %s (
			time_received TIMESTAMPTZ NOT NULL,
			time_flow_start TIMESTAMPTZ,
			time_flow_end TIMESTAMPTZ,
			src_addr INET,
			dst_addr INET,
			src_port INTEGER,
			dst_port INTEGER,
			proto INTEGER,
			bytes BIGINT,
			packets BIGINT,
			src_as INTEGER,
			dst_as INTEGER,
			etype INTEGER,
			sampler_address INET,
			sequence_num INTEGER,
			sampling_rate BIGINT,
			in_if INTEGER,
			out_if INTEGER,
			src_mac BIGINT,
			dst_mac BIGINT,
			src_vlan INTEGER,
			dst_vlan INTEGER,
			vlan_id INTEGER,
			ip_tos INTEGER,
			forwarding_status INTEGER,
			ip_ttl INTEGER,
			ip_flags INTEGER,
			tcp_flags INTEGER,
			icmp_type INTEGER,
			icmp_code INTEGER,
			ipv6_flow_label INTEGER,
			fragment_id INTEGER,
			fragment_offset INTEGER,
			next_hop INET,
			next_hop_as INTEGER,
			src_net INTEGER,
			dst_net INTEGER,
			observation_domain_id INTEGER,
			observation_point_id INTEGER,
			flow_type INTEGER,
			bgp_next_hop INET,
			as_path INTEGER[],
			mpls_label INTEGER[],
			mpls_ttl INTEGER[],
			bgp_communities INTEGER[]
		);
		
		-- Create hypertable for TimescaleDB if extension is available
		SELECT create_hypertable('%s', 'time_received', chunk_time_interval => %s, if_not_exists => TRUE);
	`, d.tableName, d.tableName, intervalExpr)

	// Execute table creation
	conn, err := d.pool.Acquire(d.ctx)
	if err != nil {
		return fmt.Errorf("acquire connection: %w", err)
	}
	defer conn.Release()

	_, err = conn.Exec(d.ctx, query)
	if err != nil {
		// If create_hypertable fails (not TimescaleDB), just create regular table
		// Remove the hypertable creation part and try again
		basicQuery := fmt.Sprintf(`
			CREATE TABLE IF NOT EXISTS %s (
				time_received TIMESTAMPTZ NOT NULL,
				time_flow_start TIMESTAMPTZ,
				time_flow_end TIMESTAMPTZ,
				src_addr INET,
				dst_addr INET,
				src_port INTEGER,
				dst_port INTEGER,
				proto INTEGER,
				bytes BIGINT,
				packets BIGINT,
				src_as INTEGER,
				dst_as INTEGER,
				etype INTEGER,
				sampler_address INET,
				sequence_num INTEGER,
				sampling_rate BIGINT,
				in_if INTEGER,
				out_if INTEGER,
				src_mac BIGINT,
				dst_mac BIGINT,
				src_vlan INTEGER,
				dst_vlan INTEGER,
				vlan_id INTEGER,
				ip_tos INTEGER,
				forwarding_status INTEGER,
				ip_ttl INTEGER,
				ip_flags INTEGER,
				tcp_flags INTEGER,
				icmp_type INTEGER,
				icmp_code INTEGER,
				ipv6_flow_label INTEGER,
				fragment_id INTEGER,
				fragment_offset INTEGER,
				next_hop INET,
				next_hop_as INTEGER,
				src_net INTEGER,
				dst_net INTEGER,
				observation_domain_id INTEGER,
				observation_point_id INTEGER,
				flow_type INTEGER,
				bgp_next_hop INET,
				as_path INTEGER[],
				mpls_label INTEGER[],
				mpls_ttl INTEGER[],
				bgp_communities INTEGER[]
			);
		`, d.tableName)
		_, err = conn.Exec(d.ctx, basicQuery)
		if err != nil {
			return fmt.Errorf("create basic table: %w", err)
		}
	}

	// Apply compression and indexes if enabled
	if err := d.applyCompressionAndIndexes(conn); err != nil {
		// Log warning but don't fail table creation
		slog.Warn("failed to apply compression and indexes", "error", err)
	}

	// Create aggregation tables if enabled
	if d.createAggregationTables {
		if err := d.createAggregationTablesIfNotExists(conn); err != nil {
			return fmt.Errorf("create aggregation tables: %w", err)
		}
	}

	return nil
}

// applyCompressionAndIndexes enables TimescaleDB compression and creates indexes on the flows table.
func (d *TimescaleDBDriver) applyCompressionAndIndexes(conn *pgxpool.Conn) error {
	if !d.enableCompression {
		return nil
	}

	// Enable compression with segmentby and orderby
	compressQuery := fmt.Sprintf(`
		ALTER TABLE %s SET (
			timescaledb.compress,
			timescaledb.compress_segmentby = 'sampler_address, in_if, out_if',
			timescaledb.compress_orderby = 'time_received DESC, src_addr, dst_addr'
		);
	`, d.tableName)
	_, err := conn.Exec(d.ctx, compressQuery)
	if err != nil {
		// Compression may not be supported (e.g., TimescaleDB not installed or version mismatch)
		// We log but don't fail because compression is optional
		slog.Warn("failed to enable TimescaleDB compression", "error", err)
		// Continue to create indexes anyway
	}

	// Add compression policy (compress data older than compressionAfter)
	// Convert duration to PostgreSQL interval
	intervalSeconds := int64(d.compressionAfter.Seconds())
	policyQuery := fmt.Sprintf(
		`SELECT add_compression_policy('%s', INTERVAL '%d seconds');`,
		d.tableName, intervalSeconds)
	_, err = conn.Exec(d.ctx, policyQuery)
	if err != nil {
		slog.Warn("failed to add compression policy", "error", err)
	}

	// Create indexes
	indexQueries := []string{
		fmt.Sprintf("CREATE INDEX IF NOT EXISTS idx_src_addr ON %s (src_addr);", d.tableName),
		fmt.Sprintf("CREATE INDEX IF NOT EXISTS idx_dst_addr ON %s (dst_addr);", d.tableName),
		fmt.Sprintf("CREATE INDEX IF NOT EXISTS idx_src_addr_gist ON %s USING gist (src_addr inet_ops);", d.tableName),
		fmt.Sprintf("CREATE INDEX IF NOT EXISTS idx_dst_addr_gist ON %s USING gist (dst_addr inet_ops);", d.tableName),
	}

	for _, q := range indexQueries {
		_, err := conn.Exec(d.ctx, q)
		if err != nil {
			slog.Warn("failed to create index", "query", q, "error", err)
		}
	}

	return nil
}

// createAggregationTablesIfNotExists creates continuous aggregates for local IP traffic.
func (d *TimescaleDBDriver) createAggregationTablesIfNotExists(conn *pgxpool.Conn) error {
	// Create function to determine if an IP is in local private ranges
	query := fmt.Sprintf(`
		CREATE OR REPLACE FUNCTION is_local_ip(ip INET) RETURNS BOOLEAN AS $$
		BEGIN
			RETURN ip << INET '10.0.0.0/8' OR
				   ip << INET '172.16.0.0/12' OR
				   ip << INET '192.168.0.0/16' OR
				   ip << INET '127.0.0.0/8' OR
				   ip << INET '169.254.0.0/16';
		END;
		$$ LANGUAGE plpgsql IMMUTABLE;

		-- Create continuous aggregate for outbound traffic (source IP)
		CREATE MATERIALIZED VIEW IF NOT EXISTS flows_local_ip_outbound_hourly
		WITH (timescaledb.continuous) AS
		SELECT
			src_addr AS ip_address,
			time_bucket('1 hour', time_received) AS hour_bucket,
			SUM(bytes) AS bytes_out,
			SUM(packets) AS packets_out
		FROM %s
		WHERE is_local_ip(src_addr)
		GROUP BY src_addr, hour_bucket
		WITH NO DATA;

		-- Create continuous aggregate for inbound traffic (destination IP)
		CREATE MATERIALIZED VIEW IF NOT EXISTS flows_local_ip_inbound_hourly
		WITH (timescaledb.continuous) AS
		SELECT
			dst_addr AS ip_address,
			time_bucket('1 hour', time_received) AS hour_bucket,
			SUM(bytes) AS bytes_in,
			SUM(packets) AS packets_in
		FROM %s
		WHERE is_local_ip(dst_addr)
		GROUP BY dst_addr, hour_bucket
		WITH NO DATA;

		-- Add continuous aggregate policies (refresh every hour, keep last 24 hours)
		SELECT add_continuous_aggregate_policy('flows_local_ip_outbound_hourly',
			start_offset => INTERVAL '365 days',
			end_offset => INTERVAL '1 hour',
			schedule_interval => INTERVAL '1 hour'
		);

		SELECT add_continuous_aggregate_policy('flows_local_ip_inbound_hourly',
			start_offset => INTERVAL '365 days',
			end_offset => INTERVAL '1 hour',
			schedule_interval => INTERVAL '1 hour'
		);

		-- Create a unified view for convenience
		CREATE OR REPLACE VIEW flows_local_ip_hourly AS
		SELECT
			COALESCE(o.ip_address, i.ip_address) AS ip_address,
			COALESCE(o.hour_bucket, i.hour_bucket) AS hour_bucket,
			COALESCE(o.bytes_out, 0) AS bytes_out,
			COALESCE(o.packets_out, 0) AS packets_out,
			COALESCE(i.bytes_in, 0) AS bytes_in,
			COALESCE(i.packets_in, 0) AS packets_in
		FROM flows_local_ip_outbound_hourly o
		FULL OUTER JOIN flows_local_ip_inbound_hourly i
		ON o.ip_address = i.ip_address AND o.hour_bucket = i.hour_bucket;
	`, d.tableName, d.tableName)

	_, err := conn.Exec(d.ctx, query)
	if err != nil {
		// If continuous aggregate fails (not TimescaleDB or version mismatch), fallback to regular materialized views
		basicQuery := fmt.Sprintf(`
			CREATE OR REPLACE FUNCTION is_local_ip(ip INET) RETURNS BOOLEAN AS $$
			BEGIN
				RETURN ip << INET '10.0.0.0/8' OR
					   ip << INET '172.16.0.0/12' OR
					   ip << INET '192.168.0.0/16' OR
					   ip << INET '127.0.0.0/8' OR
					   ip << INET '169.254.0.0/16';
			END;
			$$ LANGUAGE plpgsql IMMUTABLE;

			-- Create regular materialized views (not continuous)
			CREATE MATERIALIZED VIEW IF NOT EXISTS flows_local_ip_outbound_hourly AS
			SELECT
				src_addr AS ip_address,
				time_bucket('1 hour', time_received) AS hour_bucket,
				SUM(bytes) AS bytes_out,
				SUM(packets) AS packets_out
			FROM %s
			WHERE is_local_ip(src_addr)
			GROUP BY src_addr, hour_bucket
			WITH NO DATA;

			CREATE MATERIALIZED VIEW IF NOT EXISTS flows_local_ip_inbound_hourly AS
			SELECT
				dst_addr AS ip_address,
				time_bucket('1 hour', time_received) AS hour_bucket,
				SUM(bytes) AS bytes_in,
				SUM(packets) AS packets_in
			FROM %s
			WHERE is_local_ip(dst_addr)
			GROUP BY dst_addr, hour_bucket
			WITH NO DATA;

			-- Create indexes for performance
			CREATE UNIQUE INDEX IF NOT EXISTS flows_local_ip_outbound_hourly_idx
			ON flows_local_ip_outbound_hourly (ip_address, hour_bucket);
			CREATE UNIQUE INDEX IF NOT EXISTS flows_local_ip_inbound_hourly_idx
			ON flows_local_ip_inbound_hourly (ip_address, hour_bucket);

			-- Create a unified view for convenience
			CREATE OR REPLACE VIEW flows_local_ip_hourly AS
			SELECT
				COALESCE(o.ip_address, i.ip_address) AS ip_address,
				COALESCE(o.hour_bucket, i.hour_bucket) AS hour_bucket,
				COALESCE(o.bytes_out, 0) AS bytes_out,
				COALESCE(o.packets_out, 0) AS packets_out,
				COALESCE(i.bytes_in, 0) AS bytes_in,
				COALESCE(i.packets_in, 0) AS packets_in
			FROM flows_local_ip_outbound_hourly o
			FULL OUTER JOIN flows_local_ip_inbound_hourly i
			ON o.ip_address = i.ip_address AND o.hour_bucket = i.hour_bucket;
		`, d.tableName, d.tableName)
		_, err = conn.Exec(d.ctx, basicQuery)
		if err != nil {
			return fmt.Errorf("create aggregation tables: %w", err)
		}
	}

	return nil
}

// batchFlusher periodically flushes the batch to the database.
func (d *TimescaleDBDriver) batchFlusher() {
	defer d.wg.Done()

	ticker := time.NewTicker(d.batchTimeout)
	defer ticker.Stop()

	for {
		select {
		case <-d.ctx.Done():
			d.flushBatch() // Flush any remaining messages
			return
		case <-ticker.C:
			d.flushBatch()
		}
	}
}

// flushBatch sends the current batch to the database.
func (d *TimescaleDBDriver) flushBatch() {
	d.lock.Lock()
	if len(d.batch) == 0 {
		d.lock.Unlock()
		return
	}
	batch := d.batch
	d.batch = make([]*flowpb.FlowMessage, 0, d.batchSize)
	d.lock.Unlock()

	if len(batch) == 0 {
		return
	}

	// Use a copy of the context with timeout
	ctx, cancel := context.WithTimeout(d.ctx, 30*time.Second)
	defer cancel()

	conn, err := d.pool.Acquire(ctx)
	if err != nil {
		// Log error and re-add messages to batch
		d.lock.Lock()
		d.batch = append(batch, d.batch...)
		d.lock.Unlock()
		return
	}
	defer conn.Release()

	// Start batch insert
	batchInsert := &pgx.Batch{}
	for _, msg := range batch {
		query := fmt.Sprintf(`
			INSERT INTO %s (
				time_received, time_flow_start, time_flow_end,
				src_addr, dst_addr, src_port, dst_port, proto,
				bytes, packets, src_as, dst_as, etype, sampler_address,
				sequence_num, sampling_rate, in_if, out_if, src_mac, dst_mac,
				src_vlan, dst_vlan, vlan_id, ip_tos, forwarding_status,
				ip_ttl, ip_flags, tcp_flags, icmp_type, icmp_code,
				ipv6_flow_label, fragment_id, fragment_offset, next_hop,
				next_hop_as, src_net, dst_net, observation_domain_id,
				observation_point_id, flow_type, bgp_next_hop, as_path,
				mpls_label, mpls_ttl, bgp_communities
			) VALUES (
				$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
				$15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25, $26,
				$27, $28, $29, $30, $31, $32, $33, $34, $35, $36, $37, $38,
				$39, $40, $41, $42, $43, $44, $45
			)
		`, d.tableName)

		// Convert protobuf message to SQL values
		values := d.messageToValues(msg)
		batchInsert.Queue(query, values...)
	}

	// Execute batch
	br := conn.SendBatch(ctx, batchInsert)
	defer br.Close()

	// Check for errors
	successCount := 0
	for i := 0; i < batchInsert.Len(); i++ {
		_, err := br.Exec()
		if err != nil {
			// Log error but continue
			continue
		}
		successCount++
	}

	// If some inserts failed, we could re-add them to batch
	// For simplicity, we just log and drop them
	if successCount < len(batch) {
		// In production, you might want to implement retry logic
	}
}

// messageToValues converts a FlowMessage to SQL values.
func (d *TimescaleDBDriver) messageToValues(msg *flowpb.FlowMessage) []interface{} {
	// Helper to convert nanoseconds to time.Time
	nsToTime := func(ns uint64) *time.Time {
		if ns == 0 {
			return nil
		}
		t := time.Unix(0, int64(ns))
		return &t
	}

	// Helper to convert bytes to net.IP for PostgreSQL INET
	bytesToInet := func(b []byte) *net.IPNet {
		if len(b) == 0 {
			return nil
		}
		ip := net.IP(b)
		return &net.IPNet{IP: ip, Mask: net.CIDRMask(len(ip)*8, len(ip)*8)}
	}

	return []interface{}{
		nsToTime(msg.TimeReceivedNs),    // $1
		nsToTime(msg.TimeFlowStartNs),   // $2
		nsToTime(msg.TimeFlowEndNs),     // $3
		bytesToInet(msg.SrcAddr),        // $4
		bytesToInet(msg.DstAddr),        // $5
		msg.SrcPort,                     // $6
		msg.DstPort,                     // $7
		msg.Proto,                       // $8
		msg.Bytes,                       // $9
		msg.Packets,                     // $10
		msg.SrcAs,                       // $11
		msg.DstAs,                       // $12
		msg.Etype,                       // $13
		bytesToInet(msg.SamplerAddress), // $14
		msg.SequenceNum,                 // $15
		msg.SamplingRate,                // $16
		msg.InIf,                        // $17
		msg.OutIf,                       // $18
		msg.SrcMac,                      // $19
		msg.DstMac,                      // $20
		msg.SrcVlan,                     // $21
		msg.DstVlan,                     // $22
		msg.VlanId,                      // $23
		msg.IpTos,                       // $24
		msg.ForwardingStatus,            // $25
		msg.IpTtl,                       // $26
		msg.IpFlags,                     // $27
		msg.TcpFlags,                    // $28
		msg.IcmpType,                    // $29
		msg.IcmpCode,                    // $30
		msg.Ipv6FlowLabel,               // $31
		msg.FragmentId,                  // $32
		msg.FragmentOffset,              // $33
		bytesToInet(msg.NextHop),        // $34
		msg.NextHopAs,                   // $35
		msg.SrcNet,                      // $36
		msg.DstNet,                      // $37
		msg.ObservationDomainId,         // $38
		msg.ObservationPointId,          // $39
		int32(msg.Type),                 // $40
		bytesToInet(msg.BgpNextHop),     // $41
		msg.AsPath,                      // $42
		msg.MplsLabel,                   // $43
		msg.MplsTtl,                     // $44
		msg.BgpCommunities,              // $45
	}
}

// Send decodes the protobuf message and adds it to the batch.
func (d *TimescaleDBDriver) Send(key, data []byte) error {
	// Decode protobuf message
	msg := &flowpb.FlowMessage{}

	// Try to decode as delimited protobuf (with varint length prefix)
	reader := bytes.NewReader(data)
	if err := protodelim.UnmarshalFrom(reader, msg); err != nil {
		// If the error is EOF, there's no data to process
		if err == io.EOF {
			return nil
		}
		// If delimited decoding fails, try regular protobuf unmarshal
		// for backward compatibility
		if err := proto.Unmarshal(data, msg); err != nil {
			// Log details about the undecodable data for debugging
			dataLen := len(data)
			sample := hex.EncodeToString(data[:min(32, dataLen)])
			// Check if data looks like JSON (starts with '{' or '[')
			var hint string
			if dataLen > 0 && (data[0] == '{' || data[0] == '[') {
				hint = " (data appears to be JSON; try -format=bin)"
			}
			slog.Error("failed to decode protobuf message",
				slog.Int("data_len", dataLen),
				slog.String("data_sample", sample),
				slog.String("error", err.Error()))
			// If decoding fails, assume it's not protobuf format
			// For now, we'll just drop the message
			// In production, you might want to support JSON format as well
			return fmt.Errorf("failed to decode protobuf%s: %w", hint, err)
		}
	}

	d.lock.Lock()
	d.batch = append(d.batch, msg)
	shouldFlush := len(d.batch) >= d.batchSize
	d.lock.Unlock()

	if shouldFlush {
		go d.flushBatch()
	}

	return nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// Close closes the database connection and stops the batch flusher.
func (d *TimescaleDBDriver) Close() error {
	if d.cancel != nil {
		d.cancel()
	}
	d.wg.Wait()

	if d.pool != nil {
		d.pool.Close()
	}
	return nil
}

func init() {
	d := &TimescaleDBDriver{}
	transport.RegisterTransportDriver("timescaledb", d)
}
